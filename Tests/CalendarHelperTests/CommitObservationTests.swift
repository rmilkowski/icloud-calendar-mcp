import XCTest
import Foundation
import CSQLite
@testable import CalendarCore

final class CommitObservationTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() { for dir in directories { try? FileManager.default.removeItem(at: dir) }; super.tearDown() }
    private func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-observations-" + UUID().uuidString)
        directories.append(dir); return dir
    }
    private func store(_ directory: URL) throws -> StateStore {
        let state = try StateStore(directory: directory)
        try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "e", count: 64))
        return state
    }
    private func call(_ broker: Broker, _ operation: String, _ arguments: [String: JSON] = [:]) -> JSON {
        broker.handle(.object(["op": .string(operation), "arguments": .object(arguments)]))
    }
    private func sql(_ state: StateStore, _ query: String) throws -> [[String]] { try state.rows(query) }
    private func counters(_ state: StateStore) throws -> [JSON] { try state.commitObservationStatus()["observations"].array! }

    func testRejectedArbitraryOperationsHaveFixedStorageAndExactCountsAcrossRestart() throws {
        let dir = directory(), now = try parseDate("2026-10-24T12:00:00Z")
        var baseline: [JSON] = []
        do {
            let state = try store(dir), broker = Broker(state: state, backend: SyntheticBackend(), now: { now })
            baseline = try state.auditRecords()
            for index in 0..<500 {
                XCTAssertEqual(call(broker, "commit_attacker_\(index)_" + String(repeating: "secret", count: 20))["error"]["code"], .string("unknown_operation"))
            }
            XCTAssertEqual(try state.auditRecords(), baseline)
            let counts = try counters(state)
            XCTAssertEqual(counts.count, 1); XCTAssertEqual(counts[0]["operation"], .string("other_commit"))
            XCTAssertEqual(counts[0]["reason"], .string("invalid_request")); XCTAssertEqual(counts[0]["count"], .int(500))
            XCTAssertEqual(counts[0]["pending_count"], .int(500))
            XCTAssertFalse(try state.commitObservationStatus().text().contains("attacker"))
        }
        do {
            let state = try store(dir), broker = Broker(state: state, backend: SyntheticBackend(), now: { now.addingTimeInterval(-86400) })
            for _ in 0..<100 { _ = call(broker, "commit_more_attacker_text") }
            XCTAssertEqual(try state.auditRecords(), baseline)
            XCTAssertEqual(try counters(state)[0]["count"], .int(600))
            XCTAssertEqual(try counters(state)[0]["last_at"], .string(iso(now)))
            try state.maintainCommitObservations(now: now.addingTimeInterval(3599))
            XCTAssertEqual(try state.auditRecords(), baseline)
            try state.maintainCommitObservations(now: now.addingTimeInterval(3600))
            let records = try state.auditRecords()
            XCTAssertEqual(Array(records.prefix(baseline.count)), baseline)
            XCTAssertEqual(records.count, baseline.count + 1)
            let checkpoint = records.last!
            XCTAssertEqual(checkpoint["event"], .string("commit_observation_checkpoint"))
            XCTAssertEqual(checkpoint["approval_source"], .string("native_maintenance"))
            XCTAssertEqual(checkpoint["approval_evidence"], .string("not_provided"))
            XCTAssertEqual(checkpoint["payload"]["observations"].array![0]["count"], .int(600))
            XCTAssertEqual(try counters(state)[0]["pending_count"], .int(0))
            try state.verifyAudit()
        }
        for _ in 0..<4 {
            let state = try store(dir)
            try state.maintainCommitObservations(now: now.addingTimeInterval(-1))
            try state.recordCommitObservation(replayed: false, operation: "commit_rogue", code: "arbitrary", now: now.addingTimeInterval(-1))
            try state.recordCommitObservation(replayed: true, operation: "commit_modify", now: now.addingTimeInterval(-1))
            XCTAssertEqual(try state.auditRecords().count, baseline.count + 1)
        }
        let state = try store(dir)
        try state.maintainCommitObservations(now: now.addingTimeInterval(7200))
        XCTAssertEqual(try state.auditRecords().count, baseline.count + 2)
        XCTAssertEqual(try sql(state, "SELECT count(*) FROM commit_observations")[0][0], "3")
        try state.maintainCommitObservations(now: now.addingTimeInterval(1000000)) // Clean maintenance appends nothing.
        XCTAssertEqual(try state.auditRecords().count, baseline.count + 2)
        try state.verifyAudit()
    }

    func testReplayedRequestsPreserveImmutableHistoryQuotaAndRecordedResults() throws {
        let dir = directory(), now = try parseDate("2026-10-24T12:00:00Z")
        let state = try store(dir), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend, now: { now })
        let calendar = call(broker, "list_calendars")["result"]["calendars"].array![0]["id"]
        let preview = call(broker, "preflight_change", ["action": .string("create"), "scope": .string("this"), "calendar_id": calendar, "fields": .object(["title": .string("Synthetic"), "start": .string("2026-10-25T10:00:00Z"), "end": .string("2026-10-25T11:00:00Z")])])["result"]["preview"]
        let created = call(broker, "commit_create", ["preview": preview]), id = created["result"]["event"]["id"]
        let modification = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("this"), "event_id": id, "fields": .object(["title": .string("Changed synthetic")])])["result"]["preview"]
        let modified = call(broker, "commit_modify", ["preview": modification])
        XCTAssertEqual(modified["result"]["state"], .string("applied"))
        // Historical attempt records must remain byte-identical after the upgrade behavior.
        _ = try state.append(event: "commit_replayed", nonce: modification["envelope"]["nonce"].string, payload: modified["result"])
        _ = try state.append(event: "commit_rejected", nonce: nil, payload: .object(["op": .string("commit_delete"), "code": .string("invalid_preview")]))
        let audit = try state.auditRecords(), executions = try sql(state, "SELECT * FROM executions ORDER BY nonce"), claims = try sql(state, "SELECT * FROM write_safety_claims ORDER BY nonce")
        for _ in 0..<400 {
            XCTAssertEqual(call(broker, "commit_modify", ["preview": modification]), modified)
            XCTAssertEqual(call(broker, "commit_create", ["preview": preview]), created)
        }
        XCTAssertEqual(backend.writeCount, 2)
        XCTAssertEqual(try state.auditRecords(), audit)
        XCTAssertEqual(try sql(state, "SELECT * FROM executions ORDER BY nonce"), executions)
        XCTAssertEqual(try sql(state, "SELECT * FROM write_safety_claims ORDER BY nonce"), claims)
        XCTAssertEqual(claims.count, 1)
        let replayed = try counters(state)
        XCTAssertEqual(replayed.count, 2); XCTAssertTrue(replayed.allSatisfy { $0["kind"] == .string("replayed") && $0["count"] == .int(400) })
        try state.maintainCommitObservations(now: now.addingTimeInterval(3600))
        XCTAssertEqual(try state.auditRecords().count, audit.count + 1)
        XCTAssertEqual(Array(try state.auditRecords().prefix(audit.count)), audit)
        XCTAssertEqual(try sql(state, "SELECT * FROM executions ORDER BY nonce"), executions)
        XCTAssertEqual(try sql(state, "SELECT * FROM write_safety_claims ORDER BY nonce"), claims)
        try state.verifyAudit()
    }

    func testUpgradePreservesExistingUnknownJournalQuotasKeysAndAttemptAuditVerbatim() throws {
        let dir = directory(), tables = ["executions", "execution_details", "execution_keys", "write_safety_claims", "audit", "legacy_audit_manifest", "legacy_audit_details"]
        var snapshots: [String: [[String]]] = [:]
        var unknown = ""
        do {
            let state = try store(dir)
            for status in ["applied", "unknown"] {
                let nonce = UUID().uuidString
                _ = try state.claim(nonce: nonce, payload: .object(["action": .string("modify"), "before": .object(["id": .string("synthetic-event")]), "after": .object(["notes": .string("Synthetic retained evidence")])]), now: Date())
                try state.finish(nonce: nonce, state: status, result: .object(["nonce": .string(nonce), "state": .string(status)]), event: status == "unknown" ? "write_unknown" : "write_applied")
                _ = try state.append(event: "commit_replayed", nonce: nonce, payload: .object(["state": .string(status)]))
                if status == "unknown" { unknown = nonce }
            }
            _ = try state.append(event: "commit_rejected", nonce: nil, payload: .object(["op": .string("commit_modify"), "code": .string("unresolved_write")]))
            for table in tables { snapshots[table] = try state.rows("SELECT * FROM " + table + " ORDER BY rowid") }
            // Model an existing v2 installation before the additive accounting migration.
            try state.execute("DROP TABLE commit_observations")
            try state.execute("DROP TABLE commit_observation_clock")
        }
        let state = try store(dir)
        for table in tables { XCTAssertEqual(try state.rows("SELECT * FROM " + table + " ORDER BY rowid"), snapshots[table]) }
        XCTAssertTrue(try state.hasUnresolved())
        XCTAssertEqual(try state.execution(unknown)?.state, "unknown")
        XCTAssertEqual(try state.commitObservationStatus()["observations"], .array([]))
        XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "2")
        try state.verifyAudit()
    }

    func testCounterOverflowAndCorruptionFailClosedWithoutProviderWrites() throws {
        let state = try store(directory()), backend = SyntheticBackend(), now = try parseDate("2026-10-24T12:00:00Z"), broker = Broker(state: state, backend: backend, now: { now })
        _ = call(broker, "commit_rogue")
        try state.execute("UPDATE commit_observations SET count=?", [String(Int.max)])
        XCTAssertEqual(call(broker, "commit_rogue")["error"]["code"], .string("audit_unavailable"))
        XCTAssertEqual(try counters(state)[0]["count"], .int(Int.max))
        XCTAssertEqual(backend.writeCount, 0)
        try state.execute("UPDATE commit_observation_clock SET highwater='invalid'")
        XCTAssertEqual(call(broker, "commit_rogue")["error"]["code"], .string("audit_unavailable"))
        XCTAssertThrowsError(try state.commitObservationStatus())
        XCTAssertEqual(backend.writeCount, 0)
    }

    func testLocalRejectionCountsAndCheckpointDoNotClaimFreshHostApproval() throws {
        let state = try store(directory()), now = try parseDate("2026-10-24T12:00:00Z"), broker = Broker(state: state, backend: SyntheticBackend(), now: { now })
        XCTAssertEqual(broker.commitReviewedRollback(.null)["error"]["code"], .string("invalid_preview"))
        let count = try counters(state)[0]
        XCTAssertEqual(count["origin"], .string("local_native_ui")); XCTAssertEqual(count["count"], .int(1))
        try state.maintainCommitObservations(now: now.addingTimeInterval(3600))
        let record = try state.auditRecords().last!
        XCTAssertEqual(record["approval_source"], .string("native_maintenance"))
        XCTAssertEqual(record["approval_evidence"], .string("not_provided"))
    }

    func testIndexedRetentionIgnoresResolvedHistoryAndPreservesTransitiveHeldAncestors() throws {
        let state = try store(directory()), now = try parseDate("2026-10-24T12:00:00Z")
        let ancestor = UUID().uuidString, middle = UUID().uuidString, unknown = UUID().uuidString
        // Large resolved history has no role in unresolved retention traversal.
        for index in 0..<1500 {
            let marker: JSON = .object(["storage_version": .int(2), "action": .string("create"), "payload_digest": .string(String(repeating: "a", count: 64))])
            try state.execute("INSERT INTO executions VALUES(?,?,'applied',?,?)", ["resolved-\(index)", try marker.text(), try JSON.object(["storage_version": .int(2), "state": .string("applied")]).text(), iso(now)])
        }
        func insert(_ nonce: String, _ status: String, _ sources: [String]) throws {
            let payload: JSON = .object(["action": .string("create"), "rollback": .object(["source_change_ids": .array(sources.map(JSON.string))])])
            _ = try state.claim(nonce: nonce, payload: payload, now: now)
            if status != "intent_recorded" { try state.finish(nonce: nonce, state: status, result: .object(["state": .string(status)]), event: "synthetic_outcome") }
        }
        try insert(ancestor, "applied", [])
        try insert(middle, "applied", [ancestor])
        try insert(unknown, "unknown", [middle])
        XCTAssertEqual(try state.recoveryHeldNonces(), Set([ancestor, middle, unknown]))
        let history = try sql(state, "SELECT * FROM executions ORDER BY nonce")
        try state.expireRecoveryDetails(now: now.addingTimeInterval(10 * 86400))
        XCTAssertEqual(try state.recoveryHeldNonces(), Set([ancestor, middle, unknown]))
        XCTAssertEqual(try sql(state, "SELECT * FROM executions ORDER BY nonce"), history)
        XCTAssertEqual(try sql(state, "SELECT count(*) FROM execution_keys")[0][0], "3")
        XCTAssertTrue(try sql(state, "EXPLAIN QUERY PLAN SELECT nonce FROM executions WHERE state IN ('intent_recorded','unknown')").flatMap { $0 }.joined().contains("executions_state"))
        XCTAssertTrue(try sql(state, "EXPLAIN QUERY PLAN SELECT nonce FROM execution_details WHERE expired=0 AND expires<='2026-11-01T00:00:00Z' LIMIT 1").flatMap { $0 }.joined().contains("execution_details_expiry"))
    }
}
