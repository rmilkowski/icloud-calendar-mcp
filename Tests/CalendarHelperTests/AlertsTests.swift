import XCTest
import Foundation
import CryptoKit
@testable import CalendarCore

private final class AlertVerificationBackend: CalendarBackend {
    let base = SyntheticBackend()
    var reorder = false, drop = false, corruptMetadata = false
    func calendars() throws -> [CalendarRecord] { try base.calendars() }
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] { try base.query(start: start, end: end, calendarIDs: calendarIDs) }
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord { try base.get(nativeID: nativeID, calendarID: calendarID, occurrence: occurrence, knownStart: knownStart) }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? {
        let result = try base.apply(action: action, calendarID: calendarID, existing: existing, fields: fields)
        if result != nil, let index = base.events.indices.last {
            var details = base.events[index].details.object ?? [:]
            var alarms = details["alarms"]?.array ?? []
            if reorder { alarms.reverse() }
            if drop && !alarms.isEmpty { alarms.removeLast() }
            if corruptMetadata { details["url"] = .string("https://example.invalid/unintended") }
            details["alarms"] = .array(alarms); base.events[index].details = .object(details)
        }
        return result
    }
}

final class AlertsTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() { for dir in directories { try? FileManager.default.removeItem(at: dir) }; super.tearDown() }
    private func state() throws -> StateStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-alert-test-" + UUID().uuidString); directories.append(dir)
        let state = try StateStore(directory: dir); try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "a", count: 64)); return state
    }
    private func call(_ broker: Broker, _ op: String, _ args: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(op), "arguments": .object(args)])) }
    private func relative(_ minutes: Int) -> JSON { .object(["relative_minutes": .int(minutes)]) }
    private func draft(_ broker: Broker, fields: [String: JSON], id: JSON? = nil) -> JSON {
        var args: [String: JSON] = ["action": .string(id == nil ? "create" : "modify"), "scope": .string("this"), "fields": .object(fields)]
        if let id { args["event_id"] = id }
        else { args["calendar_id"] = call(broker, "list_calendars")["result"]["calendars"].array![0]["id"] }
        return call(broker, "preflight_change", args)
    }
    private func create(_ broker: Broker, alerts: JSON? = nil) -> JSON {
        var fields: [String: JSON] = ["title": .string("Alert fixture"), "start": .string("2026-10-25T10:00:00Z"), "end": .string("2026-10-25T11:00:00Z")]
        if let alerts { fields["alerts"] = alerts }
        return draft(broker, fields: fields)
    }
    private func commit(_ broker: Broker, _ response: JSON, action: String = "create") -> JSON { call(broker, "commit_" + action, ["preview": response["result"]["preview"]]) }
    private func sign(_ envelope: JSON, state: StateStore) throws -> JSON {
        let key = SymmetricKey(data: Data(base64Encoded: try state.metadata("signing_key")!)!)
        return .object(["envelope": envelope, "authentication_tag": .string(Data(HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: key)).base64EncodedString())])
    }
    private func rollback(_ broker: Broker, nonce: JSON) -> JSON { call(broker, "preflight_rollback", ["change_ids": .array([nonce])]) }

    func testCanonicalValidationAndElapsedMinuteContract() throws {
        let alerts = try EventAlert.parse(.array([relative(0), .object(["at": .string("2026-10-25T01:30:00+01:00")]), relative(-525600), relative(525600)]))
        XCTAssertEqual(alerts.count, 4); XCTAssertTrue(alerts.contains { $0.at == "2026-10-25T00:30:00.000Z" })
        XCTAssertEqual(try EventAlert.parse(.array(alerts.reversed().map(\.json))), alerts)
        for invalid: JSON in [.null, .object([:]), .array([.null]), .array([.object([:])]), .array([.object(["relative_minutes": .bool(true)])]), .array([relative(525601)]), .array([relative(-525601)]), .array([relative(-5), relative(-5)]), .array([.object(["relative_minutes": .int(1), "at": .string("2026-10-25T10:00:00Z")])]), .array([.object(["at": .string("2026-10-25T10:00:00")])]), .array(Array(repeating: relative(1), count: 11)), .array([.object(["at": .string("2026-10-25T10:00:00Z"), "sound": .string("x")])]), .array([.object(["at": .string("2026-10-25T10:00:00Z")]), .object(["at": .string("2026-10-25T11:00:00+01:00")])])] {
            XCTAssertThrowsError(try EventAlert.parse(invalid), "\(invalid)")
        }
        let allDay = try EventFields.merged(.object(["title": .string("DST day"), "start": .string("2026-10-25T00:00:00+01:00"), "end": .string("2026-10-26T00:00:00Z"), "all_day": .bool(true), "alerts": .array([relative(-60)])]), with: nil)
        XCTAssertEqual(allDay.alerts?.first?.rawAlarm["relative_offset"], .string("-3600.0"))
    }

    func testCreateReplaceClearOmitPreserveAndSingleQuotaIntent() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
        XCTAssertEqual(call(broker, "alerts_capabilities")["result"]["preview_version"], .int(2))
        let empty = create(broker); XCTAssertEqual(empty["result"]["preview"]["envelope"]["after"]["alerts"], .array([]))
        let result = commit(broker, create(broker, alerts: .array([relative(-10), relative(-60)])))
        XCTAssertEqual(result["result"]["state"], .string("applied")); let id = result["result"]["event"]["id"]
        XCTAssertNil(result["result"]["event"]["fields"].object?["alerts"])
        let original = backend.events[0].details["alarms"]
        let moved = commit(broker, draft(broker, fields: ["start": .string("2026-10-25T12:00:00Z"), "end": .string("2026-10-25T13:00:00Z")], id: id), action: "modify")
        XCTAssertEqual(moved["result"]["state"], .string("applied")); XCTAssertEqual(backend.events[0].details["alarms"], original)
        let before = try state.rows("SELECT nonce FROM write_safety_claims").count
        let replaced = commit(broker, draft(broker, fields: ["alerts": .array([relative(0), relative(30), .object(["at": .string("2026-10-25T14:00:00+01:00")])])], id: id), action: "modify")
        XCTAssertEqual(replaced["result"]["state"], .string("applied")); XCTAssertEqual(try state.rows("SELECT nonce FROM write_safety_claims").count, before + 1)
        XCTAssertEqual(backend.events[0].details["alarms"].array?.count, 3)
        let cleared = commit(broker, draft(broker, fields: ["alerts": .array([])], id: id), action: "modify")
        XCTAssertEqual(cleared["result"]["state"], .string("applied")); XCTAssertEqual(backend.events[0].details["alarms"], .array([]))
        XCTAssertEqual(draft(broker, fields: ["alerts": .array([])], id: id)["error"]["code"], .string("no_change"))
        XCTAssertEqual(commit(broker, empty)["result"]["state"], .string("applied")); XCTAssertEqual(backend.events.last?.details["alarms"], .array([]))
        try state.verifyAudit()
    }

    func testTamperAndRawAlarmStalenessRejectBeforeIntent() throws {
        let backend = SyntheticBackend(), state = try state(), broker = Broker(state: state, backend: backend)
        let created = commit(broker, create(broker, alerts: .array([relative(-5)]))), id = created["result"]["event"]["id"]
        let pending = draft(broker, fields: ["alerts": .array([relative(-10)])], id: id)
        var preview = pending["result"]["preview"].object!, envelope = preview["envelope"]!.object!, fields = envelope["after"]!.object!
        fields["alerts"] = .array([]); envelope["after"] = .object(fields); preview["envelope"] = .object(envelope)
        XCTAssertEqual(call(broker, "commit_modify", ["preview": .object(preview)])["error"]["code"], .string("invalid_preview"))
        backend.events[0].details = .object(["alarms": .array(try EventAlert.parse(.array([relative(-20)])).map(\.rawAlarm))])
        XCTAssertEqual(commit(broker, pending, action: "modify")["error"]["code"], .string("stale_event")); XCTAssertEqual(backend.writeCount, 1)
    }

    func testDuplicateExistingAlarmsCanBeReplacedUnsupportedRecoveryRejectsBeforeIntent() throws {
        let backend = SyntheticBackend(), state = try state(), broker = Broker(state: state, backend: backend)
        let id = commit(broker, create(broker))["result"]["event"]["id"]
        let alarm = try EventAlert(json: relative(-5)).rawAlarm
        backend.events[0].details = .object(["alarms": .array([alarm, alarm])])
        XCTAssertEqual(commit(broker, draft(broker, fields: ["alerts": .array([relative(-5)])], id: id), action: "modify")["result"]["state"], .string("applied"))
        var unsupported = alarm.object!; unsupported["type"] = .int(1) // An audio alarm without a retained sound cannot be faithfully restored.
        backend.events[0].details = .object(["alarms": .array([.object(unsupported)])])
        let writes = backend.writeCount, claims = try state.rows("SELECT nonce FROM write_safety_claims").count
        XCTAssertEqual(draft(broker, fields: ["alerts": .array([])], id: id)["error"]["code"], .string("unsupported_restore"))
        XCTAssertEqual(backend.writeCount, writes); XCTAssertEqual(try state.rows("SELECT nonce FROM write_safety_claims").count, claims)
        XCTAssertEqual(commit(broker, draft(broker, fields: ["title": .string("Preserved unsupported alarm")], id: id), action: "modify")["result"]["state"], .string("applied"))
        backend.events[0].details = .object(["alarms": .array([alarm]), "unsupported_external_alarm": .bool(true)])
        XCTAssertEqual(draft(broker, fields: ["alerts": .array([])], id: id)["error"]["code"], .string("unsupported_alarm"))
    }

    func testMixedLegacyAndNewHistoryRollsBackWithoutRewritingEncryptedPayload() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
        let id = commit(broker, create(broker))["result"]["event"]["id"]
        var envelope = draft(broker, fields: ["title": .string("Legacy title")], id: id)["result"]["preview"]["envelope"].object!
        envelope["version"] = .int(1)
        let legacy = call(broker, "commit_modify", ["preview": try sign(.object(envelope), state: state)]), legacyNonce = legacy["result"]["nonce"]
        let saved = try state.execution(legacyNonce.string!)!.payload
        let latest = commit(broker, draft(broker, fields: ["alerts": .array([relative(-5), relative(-10)])], id: id), action: "modify")
        let latestUndo = rollback(broker, nonce: latest["result"]["nonce"])["result"]["steps"].array![0]["preview"]
        XCTAssertEqual(call(broker, "commit_rollback", ["preview": latestUndo])["result"]["state"], .string("applied"))
        let legacyUndo = rollback(broker, nonce: legacyNonce)["result"]["steps"].array![0]["preview"]
        XCTAssertEqual(call(broker, "commit_rollback", ["preview": legacyUndo])["result"]["state"], .string("applied"))
        XCTAssertEqual(backend.events[0].fields.title, "Alert fixture"); XCTAssertEqual(backend.events[0].details["alarms"], .array([]))
        XCTAssertEqual(try state.execution(legacyNonce.string!)!.payload, saved); try state.verifyAudit()
    }

    func testProviderReorderAcceptedMissingAlarmAndMetadataLossUnknown() throws {
        let backend = AlertVerificationBackend(), broker = Broker(state: try state(), backend: backend)
        backend.reorder = true
        let created = commit(broker, create(broker, alerts: .array([relative(-5), relative(-60)])))
        XCTAssertEqual(created["result"]["state"], .string("applied"))
        backend.corruptMetadata = true
        let modified = commit(broker, draft(broker, fields: ["alerts": .array([relative(-10)])], id: created["result"]["event"]["id"]), action: "modify")
        XCTAssertEqual(modified["result"]["state"], .string("unknown"))
        let other = AlertVerificationBackend(), otherBroker = Broker(state: try state(), backend: other); other.drop = true
        let pending = create(otherBroker, alerts: .array([relative(-5), relative(-60)])), failed = commit(otherBroker, pending)
        XCTAssertEqual(failed["result"]["state"], .string("unknown")); XCTAssertEqual(commit(otherBroker, pending), failed); XCTAssertEqual(other.base.writeCount, 1)
    }

    func testReplacementRollbackRestoresAudioGeofenceAndDeleteRestoration() throws {
        let backend = SyntheticBackend(), state = try state(), broker = Broker(state: state, backend: backend)
        let id = commit(broker, create(broker))["result"]["event"]["id"]
        let raw: JSON = .array([.object(["absolute_date": .null, "relative_offset": .string("-123.5"), "proximity": .int(1), "structured_location": .object(["title": .string("Fixture"), "radius": .string("10.0"), "latitude": .string("51.5"), "longitude": .string("-0.1")]), "type": .int(1), "email_address": .null, "sound_name": .string("Fixture sound")])])
        backend.events[0].details = .object(["alarms": raw])
        let changed = commit(broker, draft(broker, fields: ["alerts": .array([relative(-5), relative(-10)])], id: id), action: "modify")
        let plan = rollback(broker, nonce: changed["result"]["nonce"]), preview = plan["result"]["steps"].array![0]["preview"]
        XCTAssertEqual(preview["envelope"]["rollback"]["alarm_restoration"], raw)
        XCTAssertEqual(call(broker, "commit_rollback", ["preview": preview])["result"]["state"], .string("applied")); XCTAssertEqual(backend.events[0].details["alarms"], raw)
        let deletedDraft = call(broker, "preflight_change", ["action": .string("delete"), "scope": .string("this"), "event_id": id])
        let deleted = commit(broker, deletedDraft, action: "delete"), restoration = rollback(broker, nonce: deleted["result"]["nonce"])["result"]["steps"].array![0]["preview"]
        XCTAssertEqual(call(broker, "commit_rollback", ["preview": restoration])["result"]["state"], .string("applied")); XCTAssertEqual(backend.events[0].details["alarms"], raw)
        try state.verifyAudit()
    }

    func testLegacyV1PreviewReplaySnapshotsAndRollbackRemainCompatible() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
        var envelope = create(broker)["result"]["preview"]["envelope"].object!, fields = envelope["after"]!.object!
        envelope["version"] = .int(1); fields.removeValue(forKey: "alerts"); envelope["after"] = .object(fields)
        let legacy = try sign(.object(envelope), state: state), created = call(broker, "commit_create", ["preview": legacy])
        XCTAssertEqual(created["result"]["state"], .string("applied")); XCTAssertEqual(call(broker, "commit_create", ["preview": legacy]), created)
        XCTAssertNil(created["result"]["event"]["fields"].object?["alerts"])
        let id = created["result"]["event"]["id"]
        envelope = draft(broker, fields: ["title": .string("Legacy changed")], id: id)["result"]["preview"]["envelope"].object!; envelope["version"] = .int(1)
        let changed = call(broker, "commit_modify", ["preview": try sign(.object(envelope), state: state)])
        var undoEnvelope = rollback(broker, nonce: changed["result"]["nonce"])["result"]["steps"].array![0]["preview"]["envelope"].object!
        var undoFields = undoEnvelope["rollback"]!.object!; undoFields.removeValue(forKey: "alarm_restoration"); undoEnvelope["rollback"] = .object(undoFields); undoEnvelope["version"] = .int(1)
        XCTAssertEqual(call(broker, "commit_rollback", ["preview": try sign(.object(undoEnvelope), state: state)])["result"]["state"], .string("applied"))
        XCTAssertEqual(backend.events[0].fields.title, "Alert fixture")
        var invalid = envelope, invalidFields = invalid["after"]!.object!; invalidFields["alerts"] = .array([]); invalid["after"] = .object(invalidFields); invalid["nonce"] = .string(UUID().uuidString)
        XCTAssertEqual(call(broker, "commit_modify", ["preview": try sign(.object(invalid), state: state)])["error"]["code"], .string("invalid_preview"))
        try state.verifyAudit()
    }
}
