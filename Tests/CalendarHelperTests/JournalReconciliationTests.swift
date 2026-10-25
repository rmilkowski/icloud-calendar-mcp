import XCTest
import Foundation
import CryptoKit
@testable import CalendarCore

private final class JournalClock { var value = Date().addingTimeInterval(3600) }
private final class NoCalendarBackend: CalendarBackend {
    var calls = 0
    func denied<T>() throws -> T { calls += 1; throw CoreError("test_calendar_access", "Calendar must not be accessed") }
    func calendars() throws -> [CalendarRecord] { try denied() }
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] { try denied() }
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord { try denied() }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? { try denied() }
}
final class JournalReconciliationTests: XCTestCase {
    var directories: [URL] = []
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at: directory) }; super.tearDown() }
    func directory() -> URL { let value = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-journal-test-" + UUID().uuidString); directories.append(value); return value }
    func store(_ directory: URL) throws -> StateStore { let state = try StateStore(directory: directory); try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "b", count: 64)); return state }
    func call(_ broker: Broker, _ op: String, _ args: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(op), "arguments": .object(args)])) }
    private func seed(_ state: StateStore, _ clock: JournalClock, action: String = "create", recovery: Bool = false) throws -> JSON {
        let broker = Broker(state: state, backend: SyntheticBackend(), now: { clock.value })
        let calendar = call(broker, "list_calendars")["result"]["calendars"].array!.first!["id"]
        let preview = call(broker, "preflight_change", ["action": .string("create"), "scope": .string("this"), "calendar_id": calendar, "fields": .object(["title": .string("Private fixture"), "start": .string("2028-01-01T10:00:00Z"), "end": .string("2028-01-01T11:00:00Z"), "time_zone": .string("UTC")])])["result"]["preview"]
        var payload = preview["envelope"].object!
        // Distinct calendars allow several independently unresolved synthetic intents.
        var target = payload["calendar"]!.object!; target["id"] = .string(try state.identity(kind: "calendar", nativeID: "journal-fixture-" + UUID().uuidString)); payload["calendar"] = .object(target)
        payload["action"] = .string(action)
        payload["recovery"] = broker.recoveryContract(action: action, before: payload["before"]!)
        if recovery { payload["rollback"] = .object(["source_change_ids": .array([])]) }
        let envelope = JSON.object(payload), nonce = envelope["nonce"].string!
        _ = try state.claim(nonce: nonce, payload: envelope, now: clock.value)
        try state.finish(nonce: nonce, state: "unknown", result: .object(["nonce": .string(nonce), "state": .string("unknown"), "message": .string("Private unknown evidence")]), event: "write_unknown")
        let tag = HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: try broker.signingKey())
        return .object(["envelope": envelope, "authentication_tag": .string(Data(tag).base64EncodedString())])
    }
    func preview(_ broker: Broker, id: JSON, outcome: String = "applied", evidence: String = "User inspected the event and assessed its outcome.") -> JSON {
        call(broker, "preflight_reconciliation", ["change_id": id, "outcome": .string(outcome), "evidence": .string(evidence)])["result"]["preview"]
    }
    func signed(_ broker: Broker, _ original: JSON, change: (inout [String: JSON]) -> Void, domain: String = "journal_reconciliation") throws -> JSON {
        var envelope = original["envelope"].object!; change(&envelope); let value = JSON.object(envelope)
        let tag = HMAC<SHA256>.authenticationCode(for: try broker.reconciliationAuthentication(value, domain: domain), using: try broker.signingKey())
        return .object(["envelope": value, "authentication_tag": .string(Data(tag).base64EncodedString())])
    }
    func testInventoryIncludesUnknownCreatesAndRecoveriesWithBoundedSignedPagination() throws {
        let state = try store(directory()), clock = JournalClock()
        let first = try seed(state, clock), second = try seed(state, clock, action: "modify"), third = try seed(state, clock, action: "delete", recovery: true)
        let backend = NoCalendarBackend(), broker = Broker(state: state, backend: backend, now: { clock.value })
        let result = call(broker, "list_unresolved_changes", ["limit": .int(1)])["result"]
        XCTAssertEqual(result["changes"].array?.first?["change_id"], third["envelope"]["nonce"])
        XCTAssertEqual(Set(result["changes"].array!.first!.object!.keys), ["change_id", "action", "scope", "created_at", "state", "calendar_id", "details_available"])
        _ = call(broker, "commit_reconciliation", ["preview": preview(broker, id: second["envelope"]["nonce"])])
        _ = try seed(state, clock) // New insert is outside the cursor's cutoff.
        let page = call(broker, "list_unresolved_changes", ["cursor": result["next_cursor"]])["result"]
        XCTAssertEqual(page["changes"].array?.map { $0["change_id"] }, [first["envelope"]["nonce"]]); XCTAssertEqual(page["next_cursor"], .null)
        let stored = call(broker, "get_stored_change", ["change_id": first["envelope"]["nonce"]])["result"]
        XCTAssertEqual(stored["proposed_after"], first["envelope"]["after"])
        for invalid in [JSON.int(0), .int(101), .bool(true), .null] { XCTAssertNotEqual(call(broker, "list_unresolved_changes", ["limit": invalid])["error"], .null) }
        XCTAssertNotEqual(call(broker, "list_unresolved_changes", ["cursor": .string("invalid")])["error"], .null)
        XCTAssertEqual(backend.calls, 0)
    }
    func testStatelessPreviewAssessmentPreservesHistoryQuotaAndCalendarReplay() throws {
        let state = try store(directory()), clock = JournalClock(), original = try seed(state, clock, action: "modify"), id = original["envelope"]["nonce"]
        let backend = NoCalendarBackend(), broker = Broker(state: state, backend: backend, now: { clock.value })
        let old = try state.execution(id.string!)!, audit = try state.auditRecords(), claims = try state.rows("SELECT rowid,* FROM write_safety_claims"), payload = try state.rows("SELECT rowid,nonce,payload,created FROM executions"), details = try state.rows("SELECT rowid,nonce,payload_cipher,captured,expires FROM execution_details"), keys = try state.rows("SELECT rowid,* FROM execution_keys"), identities = try state.rows("SELECT rowid,* FROM identities")
        let p = preview(broker, id: id)
        XCTAssertEqual(try state.auditRecords(), audit); XCTAssertEqual(try state.rows("SELECT * FROM reconciliation_claims"), [])
        XCTAssertEqual(p["envelope"]["source"]["payload"], old.payload); XCTAssertEqual(p["envelope"]["source"]["result"], old.result)
        let receipt = call(broker, "commit_reconciliation", ["preview": p])["result"]
        XCTAssertEqual(receipt["verification"], .string("not_performed")); XCTAssertEqual(receipt["resolution_source"], .string("user_assessment"))
        XCTAssertEqual(try state.execution(id.string!)!.result["previous_result"], old.result)
        XCTAssertEqual(try state.rows("SELECT rowid,* FROM write_safety_claims"), claims); XCTAssertEqual(try state.rows("SELECT rowid,nonce,payload,created FROM executions"), payload)
        XCTAssertEqual(try state.rows("SELECT rowid,nonce,payload_cipher,captured,expires FROM execution_details"), details); XCTAssertEqual(try state.rows("SELECT rowid,* FROM execution_keys"), keys); XCTAssertEqual(try state.rows("SELECT rowid,* FROM identities"), identities)
        let records = try state.auditRecords(); XCTAssertEqual(Array(records.prefix(audit.count)), audit); XCTAssertEqual(records.count, audit.count + 1)
        XCTAssertEqual(records.last!["approval_source"], .string("chatgpt_host_policy")); XCTAssertEqual(records.last!["approval_evidence"], .string("not_provided")); XCTAssertEqual(records.last!["event"], .string("user_reconciliation")); XCTAssertEqual(records.last!["nonce"], id)
        XCTAssertFalse(try records.last!.text().contains("User inspected")); XCTAssertFalse(try records.last!.text().contains("Private unknown"))
        XCTAssertEqual(call(broker, "commit_modify", ["preview": original])["result"], try state.execution(id.string!)!.result)
        XCTAssertEqual(call(broker, "list_changes")["result"]["changes"].array?.first?["recovery_eligible"], .bool(false))
        XCTAssertNotEqual(call(broker, "preflight_rollback", ["change_ids": .array([id])])["error"], .null)
        XCTAssertEqual(backend.calls, 0); try state.verifyAudit()
    }
    func testReplaySurvivesExpiryRestartAndDetailPurge() throws {
        let dir = directory(), clock = JournalClock(); var p: JSON!, receipt: JSON!, id: String!
        do {
            let state = try store(dir), original = try seed(state, clock); id = original["envelope"]["nonce"].string!
            let broker = Broker(state: state, backend: NoCalendarBackend(), now: { clock.value }); p = preview(broker, id: .string(id))
            receipt = call(broker, "commit_reconciliation", ["preview": p])["result"]
        }
        clock.value.addTimeInterval(7 * 86400)
        let state = try store(dir); try state.expireRecoveryDetails(now: clock.value)
        XCTAssertTrue(try state.rows("SELECT key FROM execution_keys WHERE nonce=?", [id]).isEmpty)
        let backend = NoCalendarBackend(), broker = Broker(state: state, backend: backend, now: { clock.value })
        let audit = try state.auditRecords()
        XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": p])["result"], receipt)
        XCTAssertEqual(try state.auditRecords().prefix(audit.count).map { $0 }, audit)
        XCTAssertEqual(try state.auditRecords().filter { $0["event"] == .string("user_reconciliation") }.count, 1)
        var observations = try state.commitObservationStatus()["observations"].array!
        XCTAssertEqual(observations.first { $0["kind"] == .string("replayed") && $0["operation"] == .string("other_commit") }?["count"], .int(1))
        clock.value.addTimeInterval(3601)
        XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": p])["result"], receipt)
        observations = try state.commitObservationStatus()["observations"].array!
        XCTAssertEqual(observations.first { $0["kind"] == .string("replayed") && $0["operation"] == .string("other_commit") }?["count"], .int(2))
        XCTAssertEqual(try state.auditRecords().filter { $0["event"] == .string("user_reconciliation") }.count, 1)
        XCTAssertTrue(try state.auditRecords().contains { $0["event"] == .string("commit_observation_checkpoint") })
        XCTAssertEqual(backend.calls, 0)
        XCTAssertThrowsError(try state.execute("DELETE FROM reconciliation_claims")); XCTAssertThrowsError(try state.execute("UPDATE reconciliation_claims SET receipt='{}'"))
        let conflict = try signed(broker, p) { $0["assessment"] = .object(["outcome": .string("not_applied"), "evidence": .string("Changed assessment")]) }
        XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": conflict])["error"]["code"], .string("nonce_conflict"))
    }
    func testAuthenticationDomainsTamperingStaleAndCompetingPreviewsFailClosed() throws {
        let state = try store(directory()), clock = JournalClock(), original = try seed(state, clock), backend = NoCalendarBackend(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = original["envelope"]["nonce"]
        let p = preview(broker, id: id), competing = preview(broker, id: id, outcome: "not_applied")
        var tampered = p.object!; var envelope = p["envelope"].object!; envelope["assessment"] = .object(["outcome": .string("not_applied"), "evidence": .string("tampered")]); tampered["envelope"] = .object(envelope)
        XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": .object(tampered)])["error"]["code"], .string("invalid_preview"))
        let wrongDomain = try signed(broker, p, change: { _ in }, domain: "unresolved_cursor")
        XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": wrongDomain])["error"]["code"], .string("invalid_preview"))
        for mutation: (inout [String: JSON]) -> Void in [{ $0["extra"] = .bool(true) }, { $0["kind"] = .string("calendar_change") }, { $0["installation_id"] = .string(UUID().uuidString) }] {
            XCTAssertNotEqual(call(broker, "commit_reconciliation", ["preview": try signed(broker, p, change: mutation)])["error"], .null)
        }
        let changedSource = try signed(broker, p) { value in var source = value["source"]!.object!; source["result"] = .object(["state": .string("unknown")]); value["source"] = .object(source) }
        XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": changedSource])["error"]["code"], .string("stale_reconciliation"))
        XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": p])["result"]["state"], .string("reconciled"))
        XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": competing])["error"]["code"], .string("stale_reconciliation")); XCTAssertEqual(backend.calls, 0)
    }
    func testExpiredPreviewEvidenceBoundsAndTransactionFailureDoNotResolve() throws {
        let state = try store(directory()), clock = JournalClock(), original = try seed(state, clock), backend = NoCalendarBackend(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = original["envelope"]["nonce"]
        for text in ["  \n", String(repeating: "a", count: 2001), String(repeating: "e\u{301}", count: 1001)] { XCTAssertEqual(preview(broker, id: id, evidence: text), .null) }
        XCTAssertNotEqual(preview(broker, id: id, evidence: String(repeating: "😀", count: 2000)), .null)
        let expired = preview(broker, id: id); clock.value.addTimeInterval(601)
        XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": expired])["error"]["code"], .string("preview_expired"))
        let p = preview(broker, id: id), old = try state.execution(id.string!)!, count = try state.auditRecords().count
        for table in ["audit", "reconciliation_claims"] {
            try state.execute("CREATE TRIGGER test_failure BEFORE INSERT ON \(table) BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
            XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": p])["error"]["code"], .string("audit_unavailable"))
            XCTAssertEqual(try state.execution(id.string!)!.result, old.result); XCTAssertEqual(try state.execution(id.string!)!.state, "unknown")
            XCTAssertEqual(try state.auditRecords().count, count); XCTAssertTrue(try state.rows("SELECT * FROM reconciliation_claims").isEmpty)
            try state.execute("DROP TRIGGER test_failure")
        }
        XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": p])["result"]["state"], .string("reconciled")); XCTAssertEqual(backend.calls, 0)
    }
    func testNonceNamespacesRemainDisjointForNewAndFrozenWriters() throws {
        let state = try store(directory()), clock = JournalClock(), original = try seed(state, clock), broker = Broker(state: state, backend: NoCalendarBackend(), now: { clock.value }), p = preview(broker, id: original["envelope"]["nonce"])
        let collision = try signed(broker, p) { $0["nonce"] = original["envelope"]["nonce"] }
        XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": collision])["error"]["code"], .string("nonce_conflict"))
        _ = call(broker, "commit_reconciliation", ["preview": p])
        var payload = original["envelope"].object!; payload["nonce"] = p["envelope"]["nonce"]
        XCTAssertThrowsError(try state.claim(nonce: p["envelope"]["nonce"].string!, payload: .object(payload), now: clock.value))
        XCTAssertEqual(try state.rows("SELECT * FROM executions").count, 1); XCTAssertEqual(try state.rows("SELECT * FROM execution_keys").count, 1)
    }
    func testFrozenFloorSixHelperRejectsSevenWithoutReinterpretingReconciledHistory() throws {
        guard let helper = ProcessInfo.processInfo.environment["CALENDAR_MCP_FROZEN_FLOOR6_HELPER"] else { throw XCTSkip("Set the frozen floor-6 helper for compatibility validation") }
        let dir = directory(), clock = JournalClock(); var original: JSON!, retained: [[String]]!, claims: [[String]]!
        do {
            let state = try store(dir); original = try seed(state, clock)
            let broker = Broker(state: state, backend: NoCalendarBackend(), now: { clock.value })
            _ = call(broker, "commit_reconciliation", ["preview": preview(broker, id: original["envelope"]["nonce"])])
            retained = try state.rows("SELECT rowid,* FROM executions"); claims = try state.rows("SELECT rowid,* FROM reconciliation_claims")
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["--migrate-recovery", "--state-dir", dir.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let response = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1); XCTAssertEqual(try JSON.parse(response)["error"]["code"], .string("state_version"))
        let state = try store(dir)
        XCTAssertEqual(try state.metadata("recovery_storage_version"), "7"); XCTAssertEqual(try state.rows("SELECT rowid,* FROM executions"), retained)
        XCTAssertEqual(try state.rows("SELECT rowid,* FROM reconciliation_claims"), claims); try state.verifyAudit()
    }

    func testLargeUnicodePreviewFitsCompleteNativeWrapperAndRejectsOversize() throws {
        let state = try store(directory()), clock = JournalClock(), original = try seed(state, clock)
        let backend = NoCalendarBackend(), broker = Broker(state: state, backend: backend, now: { clock.value })
        let id = original["envelope"]["nonce"].string!, unit = "🗓️é漢"
        var low = 0, high = 524_000 / unit.utf8.count, accepted: JSON = .null
        while low <= high {
            let middle = (low + high) / 2
            let result: JSON = .object(["nonce": .string(id), "state": .string("unknown"), "message": .string(String(repeating: unit, count: middle))])
            try state.transaction { try state.storeResult(nonce: id, state: "unknown", result: result) }
            let response = call(broker, "preflight_reconciliation", ["change_id": .string(id), "outcome": .string("applied"), "evidence": .string(String(repeating: "é😀", count: 1000))])
            if response["result"]["preview"] != .null { low = middle + 1; accepted = response["result"]["preview"] }
            else { XCTAssertEqual(response["error"]["code"], .string("preview_too_large")); high = middle - 1 }
        }
        let retained = accepted["envelope"]["source"]["result"]
        try state.transaction { try state.storeResult(nonce: id, state: "unknown", result: retained) }
        let request: JSON = .object(["op": .string("commit_reconciliation"), "arguments": .object(["preview": accepted])])
        let bytes = try request.data(); XCTAssertLessThanOrEqual(bytes.count, 524_288); XCTAssertGreaterThan(bytes.count, 524_200)
        XCTAssertEqual(try JSON.parse(bytes), request)
        XCTAssertEqual(broker.handle(try JSON.parse(bytes))["result"]["state"], .string("reconciled"))
        XCTAssertEqual(try state.execution(id)!.result["previous_result"], retained)
        XCTAssertEqual(backend.calls, 0)
    }

}
