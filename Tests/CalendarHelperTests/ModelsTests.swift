import XCTest
import Foundation
import CryptoKit
import CSQLite
import Darwin
@testable import CalendarCore

private final class Clock { var value = try! parseDate("2026-10-23T12:00:00Z") }
private final class Results: @unchecked Sendable {
    let lock = NSLock(); var values: [JSON] = []
    func add(_ value: JSON) { lock.lock(); values.append(value); lock.unlock() }
}
private final class AdversarialBackend: CalendarBackend {
    let base = SyntheticBackend()
    var beforeWrite: (() throws -> Void)?
    var corruptExtras = false, changeIdentity = false, ambiguityAfterDelete = false
    private var deleted = false
    func calendars() throws -> [CalendarRecord] { try base.calendars() }
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] { try base.query(start: start, end: end, calendarIDs: calendarIDs) }
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord {
        if deleted && ambiguityAfterDelete { throw CoreError("identity_ambiguous", "Synthetic ambiguous resolution") }
        return try base.get(nativeID: nativeID, calendarID: calendarID, occurrence: occurrence, knownStart: knownStart)
    }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? {
        try beforeWrite?()
        var result = try base.apply(action: action, calendarID: calendarID, existing: existing, fields: fields)
        if action == "delete" { deleted = true }
        if action == "modify", let index = base.events.indices.first, result != nil {
            if corruptExtras { base.events[index].details = .object(["alarms": .array([.string("lost original alarm")])]) }
            if changeIdentity { base.events[index].nativeID = UUID().uuidString }
            result = base.events[index]
        }
        return result
    }
}

final class ModelsTests: XCTestCase {
    func testLifetimeFIFOObservesWriterAndRejectsUnsafeEndpoints() throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = dir.appendingPathComponent("lifetime").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        var writer = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        defer { if writer >= 0 { close(writer) } }
        XCTAssertGreaterThanOrEqual(writer, 0)
        let lifetime = try LauncherLifetime(path: path)
        XCTAssertTrue(lifetime.launcherIsAlive())
        close(writer); writer = -1
        XCTAssertFalse(lifetime.launcherIsAlive())
        XCTAssertEqual(chmod(path, 0o644), 0)
        XCTAssertThrowsError(try LauncherLifetime(path: path))
        XCTAssertEqual(chmod(path, 0o600), 0)
        let link = dir.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try LauncherLifetime(path: link.path))
        let regular = dir.appendingPathComponent("regular")
        try Data().write(to: regular); XCTAssertEqual(chmod(regular.path, 0o600), 0)
        XCTAssertThrowsError(try LauncherLifetime(path: regular.path))
        XCTAssertEqual(chmod(dir.path, 0o755), 0)
        XCTAssertThrowsError(try LauncherLifetime(path: path))
    }
    func testLifetimeWatchdogStopsSyntheticBrokerWithStdinStillOpen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let override = ProcessInfo.processInfo.environment["CALENDAR_MCP_TEST_HELPER"].map { URL(fileURLWithPath: $0) }
        let candidates = [override, root.appendingPathComponent(".build/out/Products/Debug/CalendarHelper"), root.appendingPathComponent(".build/debug/CalendarHelper")].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw XCTSkip("Build CalendarHelper to exercise subprocess watchdog") }
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = dir.appendingPathComponent("lifetime").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        var writer = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        defer { if writer >= 0 { close(writer) } }
        XCTAssertGreaterThanOrEqual(writer, 0)
        let input = Pipe(), output = Pipe(), child = Process()
        child.executableURL = executable
        child.arguments = ["--serve", "--state-dir", dir.appendingPathComponent("state").path, "--backend", "synthetic", "--credential-binding", String(repeating: "a", count: 64), "--lifetime-fifo", path]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate() }; try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
        try input.fileHandleForWriting.write(contentsOf: Data("{\"op\":\"authorization_status\",\"arguments\":{}}\n".utf8))
        var item = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&item, 1, 5000) > 0 else { throw CoreError("test_timeout", "Synthetic broker did not respond to status handshake") }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
        XCTAssertGreaterThan(count, 0)
        let response = try JSON.parse(Data(bytes.prefix(max(count, 0))))
        XCTAssertEqual(response["result"]["authorization_status"], .string("not_applicable"))
        close(writer); writer = -1 // Keep request stdin open: independent lifetime must stop it.
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(child.isRunning)
        if !child.isRunning { XCTAssertEqual(child.terminationStatus, 70) }
    }
    func testSyntheticRuntimeStatusNeverConsultsLiveAuthorization() throws {
        let status = try nativeRuntimeStatus(backendMode: "synthetic", pid: 123) {
            XCTFail("Synthetic diagnostics must not consult EventKit authorization")
            return ("full_access", 3)
        }
        XCTAssertEqual(status, .object(["backend_mode": .string("synthetic"), "authorization_status": .string("not_applicable"), "authorization_status_raw": .null, "pid": .int(123)]))
        let live = try nativeRuntimeStatus(backendMode: "eventkit", pid: 456) { ("denied", 2) }
        XCTAssertEqual(live["authorization_status_raw"], .int(2))
        XCTAssertEqual(live["pid"], .int(456))
    }
    func testLocalAuthorizationDiagnosticsAreBoundedAndDoNotDumpUserInfo() throws {
        let error = NSError(domain: "Permission\nDomain", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "Permission\nfailed " + String(repeating: "x", count: 2000),
            "private_extra": "must not be emitted"
        ])
        let result = localAuthorizationFailure(error, status: 0, bundleIdentifier: "local.calendar-mcp.helper", usageDescriptionPresent: true)
        XCTAssertEqual(result["error"]["code"], .string("calendar_authorization_failed"))
        XCTAssertEqual(result["error"]["ns_error_domain"], .string("Permission Domain"))
        XCTAssertEqual(result["error"]["ns_error_code"], .int(42))
        XCTAssertEqual(result["error"]["authorization_status_raw"], .int(0))
        XCTAssertEqual(result["error"]["message"].string?.count, 1024)
        XCTAssertFalse(try result.text().contains("must not be emitted"))
    }
    private var directories: [URL] = []
    override func tearDown() { for dir in directories { try? FileManager.default.removeItem(at: dir) }; super.tearDown() }
    private func directory() -> URL { let dir = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-native-test-" + UUID().uuidString); directories.append(dir); return dir }
    private func state(_ dir: URL? = nil) throws -> StateStore {
        let state = try StateStore(directory: dir ?? directory())
        try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "a", count: 64)); return state
    }
    private func call(_ broker: Broker, _ op: String, _ args: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(op), "arguments": .object(args)])) }
    private func calendarID(_ broker: Broker) -> JSON { call(broker, "list_calendars")["result"]["calendars"].array!.first!["id"] }
    private func preview(_ broker: Broker, action: String = "create", event: JSON? = nil, fields: JSON? = nil) -> JSON {
        var args: [String: JSON] = ["action": .string(action), "scope": .string("this")]
        if action == "create" { args["calendar_id"] = calendarID(broker); args["fields"] = fields ?? .object(["title": .string("Synthetic event"), "start": .string("2026-10-25T10:00:00Z"), "end": .string("2026-10-25T11:00:00Z")]) }
        else { args["event_id"] = event; if let fields { args["fields"] = fields } }
        let response = call(broker, "preflight_change", args)
        XCTAssertEqual(response["error"], .null, "\(response)")
        return response["result"]["preview"]
    }
    private func commit(_ broker: Broker, _ preview: JSON, action: String = "create") -> JSON { call(broker, "commit_" + action, ["preview": preview]) }

    func testDatesAndStrictGregorianValidation() throws {
        let f = EventFields(title: "DST", start: "2026-10-25T00:00:00+01:00", end: "2026-10-26T00:00:00Z", timeZone: "Europe/London", allDay: true)
        let (a,b,_) = try f.dates(); XCTAssertEqual(b.timeIntervalSince(a), 25 * 3600)
        for invalid in ["2026-02-30T10:00:00Z", "2026-04-31T10:00:00Z", "2026-02-29T10:00:00Z", "2026-10-25T01:30:00", "2026-01-01T24:00:00Z"] { XCTAssertThrowsError(try parseDate(invalid), invalid) }
        XCTAssertNoThrow(try parseDate("2028-02-29T10:00:00Z"))
        XCTAssertThrowsError(try EventFields(title: "Gap", start: "2026-03-29T01:30:00+00:00", end: "2026-03-29T03:00:00+01:00", timeZone: "Europe/London", allDay: false).dates())
    }
    func testStrictJSONAndUnknownFields() throws {
        XCTAssertThrowsError(try JSON.parse(Data(#"{"a":1,"a":2}"#.utf8)))
        XCTAssertThrowsError(try JSON.parse(Data(#"{"a":1.0}"#.utf8)))
        let backend = SyntheticBackend(), broker = Broker(state: try state(), backend: backend)
        XCTAssertEqual(call(broker, "list_calendars", ["extra": .bool(true)])["error"]["code"], .string("invalid_arguments"))
        XCTAssertEqual(call(broker, "apply")["error"]["code"], .string("unknown_operation"))
        let response = call(broker, "preflight_change", ["action": .string("create"), "scope": .string("this"), "calendar_id": calendarID(broker), "fields": .object(["title": .string("X"), "start": .string("2026-10-25T10:00:00Z"), "end": .string("2026-10-25T11:00:00Z"), "attendees": .array([])])])
        XCTAssertEqual(response["error"]["code"], .string("invalid_arguments")); XCTAssertEqual(backend.writeCount, 0)
    }
    func testCalendarDeletionIsUnavailableWhileIndividualEventDeletionWorks() throws {
        let fields = EventFields(title: "Retained fixture", start: "2026-10-25T10:00:00Z", end: "2026-10-25T11:00:00Z", timeZone: "Europe/London", allDay: false)
        let backend = SyntheticBackend(events: [EventRecord(nativeID: "fixture", calendarNativeID: "synthetic-calendar", fields: fields)])
        let store = try state(), broker = Broker(state: store, backend: backend)
        let calendars = call(broker, "list_calendars")["result"]["calendars"]
        let calendar = calendars.array!.first!["id"]
        let query = call(broker, "query_events", ["start": .string("2026-10-25T00:00:00Z"), "end": .string("2026-10-26T00:00:00Z")])
        let event = query["result"]["events"].array!.first!["id"]
        let rejected: [(String, [String: JSON], String)] = [
            ("delete_calendar", ["calendar_id": calendar], "unknown_operation"),
            ("commit_delete_calendar", ["calendar_id": calendar], "unknown_operation"),
            ("preflight_change", ["action": .string("delete_calendar"), "scope": .string("this"), "calendar_id": calendar], "unsupported_scope"),
            ("preflight_change", ["action": .string("delete"), "scope": .string("this"), "calendar_id": calendar], "invalid_arguments"),
            ("preflight_change", ["action": .string("delete"), "scope": .string("this"), "calendar_id": calendar, "event_id": event], "invalid_arguments"),
            ("preflight_change", ["action": .string("delete"), "scope": .string("this"), "event_id": calendar], "identity_missing"),
            ("preflight_change", ["action": .string("delete"), "scope": .string("this"), "event_id": .string("*")], "identity_missing"),
            ("preflight_change", ["action": .string("delete"), "scope": .string("all"), "event_id": event], "unsupported_scope")
        ]
        for (operation, arguments, code) in rejected {
            XCTAssertEqual(call(broker, operation, arguments)["error"]["code"], .string(code), "\(operation): \(arguments)")
        }
        let deletion = preview(broker, action: "delete", event: event)
        // Even an authentic envelope cannot widen the native commit's action/scope contract.
        for (key, value) in [("scope", "all"), ("action", "delete_calendar")] {
            var envelope = deletion["envelope"].object!
            envelope[key] = .string(value)
            let payload = JSON.object(envelope)
            let tag = HMAC<SHA256>.authenticationCode(for: try payload.data(), using: try broker.signingKey())
            let broadened: JSON = .object(["envelope": payload, "authentication_tag": .string(Data(tag).base64EncodedString())])
            XCTAssertEqual(commit(broker, broadened, action: "delete")["error"]["code"], .string("invalid_preview"))
        }
        XCTAssertEqual(backend.writeCount, 0)
        XCTAssertEqual(backend.events.count, 1)
        XCTAssertEqual(call(broker, "list_calendars")["result"]["calendars"], calendars)
        XCTAssertFalse(try store.auditRecords().contains { $0["event"] == .string("write_intent") })
        XCTAssertEqual(commit(broker, deletion, action: "delete")["result"]["deleted"], .bool(true))
        XCTAssertEqual(backend.writeCount, 1)
        XCTAssertTrue(backend.events.isEmpty)
        XCTAssertEqual(call(broker, "list_calendars")["result"]["calendars"], calendars)
    }
    func testCreateModifyDeleteAndExpiredReplay() throws {
        let clock = Clock(), store = try state(), backend = SyntheticBackend()
        let broker = Broker(state: store, backend: backend, now: { clock.value })
        let create = preview(broker); XCTAssertEqual(backend.writeCount, 0)
        let created = commit(broker, create); XCTAssertEqual(created["result"]["state"], .string("applied"))
        let eventID = created["result"]["event"]["id"]
        let modify = preview(broker, action: "modify", event: eventID, fields: .object(["title": .string("Changed")]))
        let modified = commit(broker, modify, action: "modify")
        XCTAssertEqual(modified["result"]["event"]["id"], eventID)
        let delete = preview(broker, action: "delete", event: eventID)
        let deleted = commit(broker, delete, action: "delete"); XCTAssertEqual(deleted["result"]["deleted"], .bool(true))
        clock.value.addTimeInterval(3600)
        XCTAssertEqual(commit(broker, delete, action: "delete"), deleted)
        XCTAssertEqual(commit(broker, modify, action: "modify"), modified)
        XCTAssertEqual(backend.writeCount, 3); XCTAssertEqual(backend.events.count, 0)
        try store.verifyAudit(); let records = try store.auditRecords()
        XCTAssertEqual(records.filter { $0["event"] == .string("write_intent") }.count, 3)
        XCTAssertTrue(records.contains { $0["event"] == .string("commit_replayed") })
    }
    func testTamperExpiryActionAndCredentialBinding() throws {
        let clock = Clock(), store = try state(), backend = SyntheticBackend()
        let broker = Broker(state: store, backend: backend, now: { clock.value })
        let original = preview(broker)
        var altered = original.object!; var envelope = altered["envelope"]!.object!; var fields = envelope["after"]!.object!
        fields["title"] = .string("Unapproved replacement"); envelope["after"] = .object(fields); altered["envelope"] = .object(envelope)
        XCTAssertEqual(commit(broker, .object(altered))["error"]["code"], .string("invalid_preview"))
        XCTAssertEqual(commit(broker, original, action: "delete")["error"]["code"], .string("invalid_preview"))
        clock.value.addTimeInterval(601); XCTAssertEqual(commit(broker, original)["error"]["code"], .string("preview_expired"))
        clock.value.addTimeInterval(-601)
        try store.configure(backendMode: "synthetic", credentialBinding: String(repeating: "b", count: 64))
        XCTAssertEqual(commit(broker, original)["error"]["code"], .string("invalid_preview"))
        XCTAssertThrowsError(try store.configure(backendMode: "eventkit", credentialBinding: String(repeating: "b", count: 64)))
        XCTAssertEqual(backend.writeCount, 0)
    }
    func testStaleAndMeetingReadOnlyGuards() throws {
        let backend = SyntheticBackend(), broker = Broker(state: try state(), backend: backend)
        let created = commit(broker, preview(broker)); let id = created["result"]["event"]["id"]
        let pending = preview(broker, action: "modify", event: id, fields: .object(["notes": .string("Planned")]))
        backend.events[0].fields.title = "Changed elsewhere"
        XCTAssertEqual(commit(broker, pending, action: "modify")["error"]["code"], .string("stale_event"))
        backend.events[0].hasAttendees = true
        XCTAssertEqual(call(broker, "preflight_change", ["action": .string("delete"), "scope": .string("this"), "event_id": id])["error"]["code"], .string("unsupported_meeting"))
        backend.calendarRecords = [CalendarRecord(nativeID: "synthetic-calendar", title: "Synthetic Calendar", source: "Synthetic", writable: false)]
        XCTAssertEqual(call(broker, "preflight_change", ["action": .string("delete"), "scope": .string("this"), "event_id": id])["error"]["code"], .string("read_only"))
        XCTAssertEqual(backend.writeCount, 1)
    }
    func testPostWriteCrashUnknownGateAndReconciliation() throws {
        let store = try state(), backend = SyntheticBackend(), broker = Broker(state: store, backend: backend)
        let pending = preview(broker); backend.throwAfterWrite = true
        let result = commit(broker, pending); XCTAssertEqual(result["result"]["state"], .string("unknown")); XCTAssertEqual(backend.events.count, 1)
        XCTAssertEqual(commit(broker, pending), result); XCTAssertEqual(backend.writeCount, 1)
        XCTAssertEqual(commit(broker, preview(broker))["error"]["code"], .string("unresolved_write"))
        let nonce = pending["envelope"]["nonce"].string!
        _ = try store.reconcile(nonce: nonce, outcome: "applied", evidence: "Synthetic backend inspected: one exact event exists")
        XCTAssertEqual(commit(broker, pending)["result"]["state"], .string("reconciled")); XCTAssertEqual(backend.writeCount, 1)
        XCTAssertFalse(try store.hasUnresolved())
        XCTAssertEqual(try store.auditRecords().last?["approval_source"], .string("chatgpt_host_policy")) // replay provenance
    }
    func testStrandedIntentRecoveredWithoutWrite() throws {
        let dir = directory(); var nonce = ""
        do {
            let store = try state(dir), broker = Broker(state: store, backend: SyntheticBackend())
            let pending = preview(broker); nonce = pending["envelope"]["nonce"].string!
            _ = try store.claim(nonce: nonce, payload: pending["envelope"], now: Date())
        }
        let store = try state(dir); XCTAssertEqual(try store.execution(nonce)?.state, "unknown")
        XCTAssertTrue(try store.hasUnresolved()); try store.verifyAudit()
        XCTAssertEqual(try store.auditRecords().last?["event"], .string("recovered_unknown"))
    }
    func testIntentDurableBeforeBackendAndConcurrentReplay() throws {
        let store = try state(), backend = AdversarialBackend(), broker = Broker(state: store, backend: backend)
        let pending = preview(broker), nonce = pending["envelope"]["nonce"].string!
        backend.beforeWrite = { XCTAssertEqual(try store.execution(nonce)?.state, "intent_recorded"); XCTAssertEqual(try store.auditRecords().last?["event"], .string("write_intent")); try store.verifyAudit() }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in results.add(broker.handle(.object(["op": .string("commit_create"), "arguments": .object(["preview": pending])]))) }
        XCTAssertEqual(backend.base.writeCount, 1); XCTAssertEqual(Set(try results.values.map { try $0.text() }).count, 1)
    }
    func testPreservationAndSavedIdentityProvenance() throws {
        let backend = AdversarialBackend(), broker = Broker(state: try state(), backend: backend)
        let id = commit(broker, preview(broker))["result"]["event"]["id"]
        backend.changeIdentity = true
        let changed = commit(broker, preview(broker, action: "modify", event: id, fields: .object(["title": .string("Renamed")])), action: "modify")
        XCTAssertEqual(changed["result"]["event"]["id"], id)
        XCTAssertEqual(call(broker, "get_event", ["event_id": id])["result"]["event"]["fields"]["title"], .string("Renamed"))
        backend.corruptExtras = true
        let corrupt = commit(broker, preview(broker, action: "modify", event: id, fields: .object(["title": .string("Another")])), action: "modify")
        XCTAssertEqual(corrupt["result"]["state"], .string("unknown"))
    }
    func testAmbiguousDeleteIsUnknown() throws {
        let backend = AdversarialBackend(), broker = Broker(state: try state(), backend: backend)
        let id = commit(broker, preview(broker))["result"]["event"]["id"]
        backend.ambiguityAfterDelete = true
        XCTAssertEqual(commit(broker, preview(broker, action: "delete", event: id), action: "delete")["result"]["state"], .string("unknown"))
    }
    func testAvailabilityAndNilTimezonePreservation() throws {
        let fields = EventFields(title: "Floating", start: "2026-10-25T10:00:00.000Z", end: "2026-10-25T11:00:00.000Z", timeZone: nil, allDay: false)
        let backend = SyntheticBackend(events: [EventRecord(nativeID: "floating", calendarNativeID: "synthetic-calendar", fields: fields, availability: "unknown")])
        let broker = Broker(state: try state(), backend: backend)
        let query = call(broker, "query_events", ["start": .string("2026-10-25T00:00:00Z"), "end": .string("2026-10-26T00:00:00Z")])
        let id = query["result"]["events"].array!.first!["id"]
        let modified = commit(broker, preview(broker, action: "modify", event: id, fields: .object(["title": .string("Still floating")])), action: "modify")
        XCTAssertEqual(modified["result"]["event"]["fields"]["time_zone"], .null)
        let busy = call(broker, "get_availability", ["start": .string("2026-10-25T00:00:00Z"), "end": .string("2026-10-26T00:00:00Z")])
        XCTAssertEqual(busy["result"]["busy"].array?.count, 1); XCTAssertEqual(busy["result"]["snapshot_only"], .bool(true))
        backend.events[0].availability = "free"
        XCTAssertEqual(call(broker, "get_availability", ["start": .string("2026-10-25T00:00:00Z"), "end": .string("2026-10-26T00:00:00Z")])["result"]["busy"], .array([]))
    }
    func testStatePermissionsAndAuditTamperDetection() throws {
        let dir = directory()
        do {
            let store = try state(dir); try store.append(event: "fixture", nonce: nil, payload: .object([:]))
            let permissions = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(permissions.intValue & 0o777, 0o700)
            XCTAssertThrowsError(try StateStore(directory: dir))
        }
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("state.sqlite3").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER audit_no_update; UPDATE audit SET body='{}' WHERE sequence=1", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        XCTAssertThrowsError(try StateStore(directory: dir)) { XCTAssertEqual(($0 as? CoreError)?.code, "audit_corrupt") }
    }
}
