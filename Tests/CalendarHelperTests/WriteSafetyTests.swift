// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import Foundation
import CSQLite
import Darwin
@testable import CalendarCore

private final class SafetyClock { var value = try! parseDate("2026-10-24T12:00:00Z") }
private final class SafetyResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [JSON] = []
    func add(_ value: JSON) { lock.lock(); values.append(value); lock.unlock() }
}

final class WriteSafetyTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() { for dir in directories { try? FileManager.default.removeItem(at: dir) }; super.tearDown() }
    private func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-safety-test-" + UUID().uuidString)
        directories.append(dir); return dir
    }
    private func store(_ dir: URL) throws -> StateStore {
        let state = try StateStore(directory: dir)
        try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "a", count: 64)); return state
    }
    private func policy(_ dir: URL, deleteHour: Int = 2, deleteDay: Int = 3, combinedHour: Int = 3, combinedDay: Int = 5) throws {
        let json: JSON = .object(["version": .int(1), "delete_hour": .int(deleteHour), "delete_day": .int(deleteDay), "destructive_hour": .int(combinedHour), "destructive_day": .int(combinedDay)])
        let path = dir.appendingPathComponent("write-safety.json")
        try json.data().write(to: path, options: .atomic); XCTAssertEqual(chmod(path.path, 0o600), 0)
    }
    private func backend(_ count: Int = 3) -> SyntheticBackend {
        SyntheticBackend(events: (0..<count).map { EventRecord(nativeID: "fixture-\($0)", calendarNativeID: "synthetic-calendar", fields: EventFields(title: "Fixture \($0)", start: "2026-10-25T10:00:00Z", end: "2026-10-25T11:00:00Z", timeZone: "Europe/London", allDay: false)) })
    }
    private func call(_ broker: Broker, _ op: String, _ args: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(op), "arguments": .object(args)])) }
    private func ids(_ broker: Broker) -> [JSON] {
        call(broker, "query_events", ["start": .string("2026-10-25T00:00:00Z"), "end": .string("2026-10-26T00:00:00Z")])["result"]["events"].array!.map { $0["id"] }
    }
    private func preflight(_ broker: Broker, _ id: JSON, action: String = "delete", title: String = "Changed") -> JSON {
        var args: [String: JSON] = ["action": .string(action), "scope": .string("this"), "event_id": id]
        if action == "modify" { args["fields"] = .object(["title": .string(title)]) }
        return call(broker, "preflight_change", args)
    }
    private func commit(_ broker: Broker, _ draft: JSON, action: String = "delete") -> JSON {
        call(broker, "commit_" + action, ["preview": draft["result"]["preview"]])
    }
    private func sql(_ dir: URL, _ statement: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("state.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw CoreError("test_sql", "Synthetic SQL failed") }
    }

    func testDefaultAllowsDozensAndRejectsFiftyFirstDeleteWithoutClaim() throws {
        let dir = directory(), state = try store(dir), backend = backend(51), clock = SafetyClock()
        let broker = Broker(state: state, backend: backend, now: { clock.value }), events = ids(broker)
        let auditBefore = try state.auditRecords().count
        let first = preflight(broker, events[0])
        XCTAssertEqual(first["result"]["safety"]["usage"]["delete_hour"]["limit"], .int(50))
        XCTAssertEqual(first["result"]["safety"]["usage"]["destructive_hour"]["limit"], .int(100))
        XCTAssertEqual(try state.auditRecords().count, auditBefore) // No preflight reservation or audit.
        for id in events.prefix(50) { XCTAssertEqual(commit(broker, preflight(broker, id))["result"]["state"], .string("applied")) }
        let denied = preflight(broker, events[50])
        XCTAssertEqual(denied["result"]["safety"]["allowed_now"], .bool(false))
        XCTAssertEqual(commit(broker, denied)["error"]["code"], .string("write_safety_limit"))
        XCTAssertNil(try state.execution(denied["result"]["preview"]["envelope"]["nonce"].string!))
        XCTAssertEqual(backend.writeCount, 50)
        XCTAssertFalse(try state.auditRecords().contains { $0["event"] == .string("write_safety_rejected") })
        let rejection = try state.commitObservationStatus()["observations"].array!.first { $0["reason"] == .string("write_safety_limit") }
        XCTAssertEqual(rejection?["kind"], .string("rejected")); XCTAssertEqual(rejection?["count"], .int(1))
        XCTAssertEqual(rejection?["pending_count"], .int(1))
        try state.verifyAudit()
    }

    func testCombinedBudgetCountsRepeatedModificationsAndDeletes() throws {
        let dir = directory(), state = try store(dir), backend = backend(), clock = SafetyClock()
        try policy(dir, deleteHour: 2, deleteDay: 3, combinedHour: 3, combinedDay: 5)
        let broker = Broker(state: state, backend: backend, now: { clock.value }), events = ids(broker)
        for title in ["First", "Second"] { XCTAssertEqual(commit(broker, preflight(broker, events[0], action: "modify", title: title), action: "modify")["result"]["state"], .string("applied")) }
        XCTAssertEqual(commit(broker, preflight(broker, events[1]))["result"]["state"], .string("applied"))
        let denied = preflight(broker, events[0], action: "modify", title: "Third")
        XCTAssertEqual(denied["result"]["safety"]["usage"]["delete_hour"]["remaining"], .int(1))
        XCTAssertEqual(commit(broker, denied, action: "modify")["error"]["code"], .string("write_safety_limit"))
        XCTAssertEqual(backend.writeCount, 3)
    }

    func testRollingHourAndDayExpireAtExactBoundary() throws {
        let dir = directory(), state = try store(dir), clock = SafetyClock(), backend = backend(5)
        try policy(dir, deleteHour: 2, deleteDay: 3, combinedHour: 2, combinedDay: 3)
        let broker = Broker(state: state, backend: backend, now: { clock.value }), events = ids(broker)
        for id in events.prefix(2) { XCTAssertEqual(commit(broker, preflight(broker, id))["result"]["state"], .string("applied")) }
        clock.value.addTimeInterval(3599)
        XCTAssertEqual(commit(broker, preflight(broker, events[2]))["error"]["code"], .string("write_safety_limit"))
        clock.value.addTimeInterval(1)
        XCTAssertEqual(commit(broker, preflight(broker, events[2]))["result"]["state"], .string("applied"))
        let denied = preflight(broker, events[3])
        XCTAssertEqual(denied["result"]["safety"]["retry_at"], .string("2026-10-25T12:00:00.000Z"))
        clock.value.addTimeInterval(82_800)
        XCTAssertEqual(commit(broker, preflight(broker, events[3]))["result"]["state"], .string("applied"))
        XCTAssertEqual(backend.writeCount, 4)
    }

    func testCommitRechecksChangedPolicyAndAuditsAdoptionWithoutClaim() throws {
        let dir = directory(), state = try store(dir), clock = SafetyClock(), backend = backend()
        let broker = Broker(state: state, backend: backend, now: { clock.value }), events = ids(broker)
        XCTAssertEqual(commit(broker, preflight(broker, events[0]))["result"]["state"], .string("applied"))
        let old = preflight(broker, events[1])
        try policy(dir, deleteHour: 1, deleteDay: 1, combinedHour: 1, combinedDay: 1)
        XCTAssertEqual(commit(broker, old)["error"]["code"], .string("write_safety_limit"))
        XCTAssertEqual(try state.metadata("write_safety_file_adopted"), "true")
        XCTAssertEqual(try state.metadata("write_safety_revision"), "2")
        XCTAssertNil(try state.execution(old["result"]["preview"]["envelope"]["nonce"].string!))
        let audit = try state.auditRecords().filter { $0["event"] == .string("write_safety_policy_changed") }.last!
        XCTAssertEqual(audit["approval_source"], .string("local_configuration"))
        XCTAssertEqual(audit["payload"]["previous"]["delete_hour"], .int(50))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("write-safety.json"))
        XCTAssertEqual(commit(broker, old)["error"]["code"], .string("write_safety_configuration"))
        try policy(dir, deleteHour: 2, deleteDay: 2, combinedHour: 2, combinedDay: 2)
        XCTAssertEqual(commit(broker, old)["result"]["state"], .string("applied")) // Same exact preview, current budget.
    }

    func testRestartRollbackCredentialsAndFileChangesNeverResetUsage() throws {
        let dir = directory(), clock = SafetyClock(), backend = backend(), event: JSON
        do {
            let state = try store(dir); try policy(dir, deleteHour: 1, deleteDay: 2, combinedHour: 1, combinedDay: 2)
            let broker = Broker(state: state, backend: backend, now: { clock.value }); event = ids(broker)[0]
            XCTAssertEqual(commit(broker, preflight(broker, event, action: "modify"), action: "modify")["result"]["state"], .string("applied"))
            try state.rotateCredentials()
        }
        clock.value.addTimeInterval(-3600)
        let state = try store(dir), broker = Broker(state: state, backend: backend, now: { clock.value })
        let denied = preflight(broker, event, action: "modify", title: "Again")
        XCTAssertEqual(denied["result"]["safety"]["clock_rollback"], .bool(true))
        XCTAssertEqual(denied["result"]["safety"]["effective_at"], .string("2026-10-24T12:00:00.000Z"))
        XCTAssertEqual(commit(broker, denied, action: "modify")["error"]["code"], .string("write_safety_limit"))
        try policy(dir, deleteHour: 2, deleteDay: 2, combinedHour: 2, combinedDay: 2)
        XCTAssertEqual(preflight(broker, event, action: "modify", title: "Again")["result"]["safety"]["usage"]["destructive_hour"]["used"], .int(1))
    }

    func testUnknownReconciliationAndReplayDoNotRefundOrRecharge() throws {
        let dir = directory(), state = try store(dir), backend = backend(), clock = SafetyClock()
        try policy(dir, deleteHour: 1, deleteDay: 1, combinedHour: 1, combinedDay: 1)
        let broker = Broker(state: state, backend: backend, now: { clock.value }), event = ids(broker)[0]
        let draft = preflight(broker, event, action: "modify")
        backend.throwAfterWrite = true
        XCTAssertEqual(commit(broker, draft, action: "modify")["result"]["state"], .string("unknown"))
        let nonce = draft["result"]["preview"]["envelope"]["nonce"].string!
        _ = try state.reconcile(nonce: nonce, outcome: "not_applied", evidence: "Synthetic attestation tests accounting without refunds")
        XCTAssertEqual(commit(broker, draft, action: "modify")["result"]["state"], .string("reconciled"))
        XCTAssertEqual(commit(broker, preflight(broker, event, action: "modify", title: "Again"), action: "modify")["error"]["code"], .string("write_safety_limit"))
        XCTAssertEqual(try state.auditRecords().filter { $0["event"] == .string("write_safety_charged") }.count, 1)
        XCTAssertEqual(backend.writeCount, 1)
    }

    func testInvalidOrMissingAdoptedFilePreservesReadsCreatesReplayAndStartup() throws {
        let dir = directory(), clock = SafetyClock(), backend = backend(), completed: JSON, draft: JSON, event: JSON
        do {
            let state = try store(dir); try policy(dir)
            let broker = Broker(state: state, backend: backend, now: { clock.value }); let events = ids(broker); event = events[1]
            draft = preflight(broker, events[0]); completed = commit(broker, draft)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("write-safety.json"))
            XCTAssertEqual(preflight(broker, event)["error"]["code"], .string("write_safety_configuration"))
            XCTAssertEqual(commit(broker, draft), completed)
        }
        let state = try store(dir), broker = Broker(state: state, backend: backend, now: { clock.value })
        XCTAssertEqual(preflight(broker, event)["error"]["code"], .string("write_safety_configuration"))
        XCTAssertEqual(call(broker, "get_event", ["event_id": event])["error"], .null)
        XCTAssertEqual(commit(broker, draft), completed)
        let calendar = call(broker, "list_calendars")["result"]["calendars"].array!.first!["id"]
        let create = call(broker, "preflight_change", ["action": .string("create"), "scope": .string("this"), "calendar_id": calendar, "fields": .object(["title": .string("Still available"), "start": .string("2026-10-25T12:00:00Z"), "end": .string("2026-10-25T13:00:00Z")])])
        XCTAssertEqual(create["result"]["safety"]["applies"], .bool(false))
        XCTAssertEqual(commit(broker, create, action: "create")["result"]["state"], .string("applied"))
    }

    func testUnsafeAndInvalidPoliciesFailClosedWithoutAdoption() throws {
        let dir = directory(), state = try store(dir), clock = SafetyClock(), path = dir.appendingPathComponent("write-safety.json")
        for text in ["{}", #"{"version":1,"delete_hour":true,"delete_day":3,"destructive_hour":3,"destructive_day":5}"#, #"{"version":1,"version":1,"delete_hour":2,"delete_day":3,"destructive_hour":3,"destructive_day":5}"#, #"{"version":1,"delete_hour":4,"delete_day":3,"destructive_hour":3,"destructive_day":5}"#] {
            try Data(text.utf8).write(to: path); XCTAssertEqual(chmod(path.path, 0o600), 0)
            XCTAssertThrowsError(try state.writeSafety(action: "delete", now: clock.value))
        }
        try policy(dir); XCTAssertEqual(chmod(path.path, 0o644), 0)
        XCTAssertThrowsError(try state.writeSafety(action: "modify", now: clock.value))
        XCTAssertEqual(chmod(path.path, 0o600), 0)
        let target = dir.appendingPathComponent("other-policy.json")
        try FileManager.default.moveItem(at: path, to: target)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        XCTAssertThrowsError(try state.writeSafety(action: "delete", now: clock.value))
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(try state.writeSafety(action: "delete", now: clock.value)["allowed_now"], .bool(true)) // Invalid files were never adopted.
        XCTAssertEqual(try state.metadata("write_safety_file_adopted"), "false")
    }

    func testConcurrentDistinctNoncesCannotExceedLimit() throws {
        let dir = directory(), state = try store(dir), clock = SafetyClock(), backend = backend()
        try policy(dir, deleteHour: 1, deleteDay: 1, combinedHour: 1, combinedDay: 1)
        let broker = Broker(state: state, backend: backend, now: { clock.value }), events = ids(broker)
        let requests = events.prefix(2).map { preflight(broker, $0)["result"]["preview"] }, results = SafetyResults()
        DispatchQueue.concurrentPerform(iterations: requests.count) { i in results.add(broker.handle(.object(["op": .string("commit_delete"), "arguments": .object(["preview": requests[i]])]))) }
        XCTAssertEqual(results.values.filter { $0["result"]["state"] == .string("applied") }.count, 1)
        XCTAssertEqual(results.values.filter { $0["error"]["code"] == .string("write_safety_limit") }.count, 1)
        XCTAssertEqual(backend.writeCount, 1)
    }

    func testLegacyJournalBackfillIncludesUnknownAndReconciledAttempts() throws {
        let dir = directory(), clock = SafetyClock()
        do {
            let state = try store(dir)
            for (action, outcome) in [("modify", "reconciled"), ("delete", "unknown")] {
                let nonce = UUID().uuidString
                _ = try state.claim(nonce: nonce, payload: .object(["action": .string(action)]), now: clock.value)
                try state.finish(nonce: nonce, state: outcome, result: .object([:]), event: "synthetic_fixture")
            }
        }
        try sql(dir, "DROP TABLE write_safety_claims") // Simulate the pre-policy schema.
        let state = try store(dir)
        let safety = try state.writeSafety(action: "delete", now: clock.value)
        XCTAssertEqual(safety["usage"]["delete_hour"]["used"], .int(1))
        XCTAssertEqual(safety["usage"]["destructive_hour"]["used"], .int(2))
        XCTAssertThrowsError(try sql(dir, "DELETE FROM write_safety_claims"))
        XCTAssertThrowsError(try sql(dir, "UPDATE write_safety_claims SET charged_at='2020-01-01T00:00:00.000Z'"))
    }

    func testIntentFailureRollsBackQuotaAndConfigurationAdoption() throws {
        let dir = directory(), state = try store(dir), clock = SafetyClock()
        try policy(dir)
        try sql(dir, "CREATE TRIGGER synthetic_claim_failure BEFORE INSERT ON executions BEGIN SELECT RAISE(ABORT,'synthetic intent failure'); END")
        let nonce = UUID().uuidString
        XCTAssertThrowsError(try state.claim(nonce: nonce, payload: .object(["action": .string("delete")]), now: clock.value))
        XCTAssertNil(try state.execution(nonce))
        XCTAssertEqual(try state.metadata("write_safety_file_adopted"), "false")
        XCTAssertEqual(try state.writeSafety(action: "delete", now: clock.value)["usage"]["delete_hour"]["used"], .int(0))
        XCTAssertFalse(try state.auditRecords().contains { $0["event"] == .string("write_safety_charged") })
    }

    func testMalformedLegacyJournalFailsClosedWithoutPartialBackfill() throws {
        for (action, timestamp) in [("invalid", "2026-10-24T12:00:00Z"), ("delete", "invalid")] {
            let dir = directory()
            do { _ = try store(dir) }
            try sql(dir, "DROP TRIGGER execution_v2_insert") // Simulate an actual pre-v2 journal, before the downgrade fence exists.
            try sql(dir, "INSERT INTO executions VALUES('legacy-fixture','{\"action\":\"\(action)\"}','applied','{}','\(timestamp)')")
            XCTAssertThrowsError(try store(dir))
        }
    }

    func testRecoveryV2FencesOldHelperWritesWithoutResettingExistingLedger() throws {
        let dir = directory(), clock = SafetyClock()
        do {
            let state = try store(dir), nonce = UUID().uuidString
            _ = try state.claim(nonce: nonce, payload: .object(["action": .string("modify")]), now: clock.value)
            try state.finish(nonce: nonce, state: "applied", result: .object([:]), event: "synthetic_fixture")
        }
        // An old binary cannot insert an intent into upgraded storage.
        XCTAssertThrowsError(try sql(dir, "INSERT INTO executions VALUES('\(UUID().uuidString)','{\"action\":\"delete\"}','applied','{}','2026-10-24T12:00:00.000Z')"))
        let state = try store(dir), safety = try state.writeSafety(action: "delete", now: clock.value)
        XCTAssertEqual(safety["usage"]["delete_hour"]["used"], .int(0))
        XCTAssertEqual(safety["usage"]["destructive_hour"]["used"], .int(1))
        XCTAssertEqual(try state.metadata("write_safety_revision"), "1")
    }
}
