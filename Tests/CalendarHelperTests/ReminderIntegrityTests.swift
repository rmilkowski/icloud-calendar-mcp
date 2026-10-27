// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import Foundation
import CSQLite
@testable import CalendarCore

private final class ReminderUnenteredFixture: ReminderBackend {
    func lists() throws -> [ReminderListRecord] { [ReminderListRecord(nativeID: "fixture-list", title: "Fixture", source: "Synthetic")] }
    func query(listID: String) throws -> [ReminderRecord] { [] }
    func get(nativeID: String, listID: String) throws -> ReminderRecord { throw CoreError("reminder_missing", "Missing fixture") }
    func apply(action: String, listID: String, existing: ReminderRecord?, fields: ReminderFields?, completed: Bool?, changedFields: [String], completionPolicy: String, completionDate: Date?, restoration: JSON?) throws -> ReminderWriteResult { try ProviderMutationAttempt.run { _ in throw CoreError("read_only", "Private preflight fixture") } }
}

final class ReminderIntegrityTests: XCTestCase {
    let binding = String(repeating: "b", count: 64)
    func directory() throws -> URL { let path = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-integrity-" + UUID().uuidString); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); addTeardownBlock { try? FileManager.default.removeItem(at: path) }; return path }
    func open(_ path: URL) throws -> ReminderStateStore { try ReminderStateStore(directory: path, backendMode: "synthetic", credentialBinding: binding) }
    func call(_ broker: ReminderBroker, _ op: String, _ args: JSON = .object([:])) throws -> JSON {
        let response = broker.handle(.object(["op": .string(op), "arguments": args])); guard response["error"] == .null else { throw CoreError(response["error"]["code"].string!, response["error"]["message"].string!) }; return response["result"]
    }
    func createPreview(_ broker: ReminderBroker) throws -> JSON {
        let list = try call(broker, "list_reminder_lists")["lists"].array![0]["id"]
        return try call(broker, "preflight_reminder_change", .object(["action": .string("create"), "scope": .string("this"), "list_id": list, "fields": .object(["title": .string("Private fixture")])]))["preview"]
    }
    func prepare(_ path: URL, proof: Bool) throws -> (String, JSON) {
        let state = try open(path), broker = ReminderBroker(state: state, backend: ReminderUnenteredFixture()), preview = try createPreview(broker), nonce = preview["envelope"]["nonce"].string!
        if proof { XCTAssertEqual(try call(broker, "commit_reminder_create", .object(["preview": preview]))["state"], .string("not_applied")) }
        else { _ = try state.claim(nonce: nonce, payload: preview["envelope"], now: Date()) }
        return (nonce, preview)
    }
    func testNativeProofSurvivesExpiryAndRestartReplay() throws {
        let path = try directory(), (nonce, preview) = try prepare(path, proof: true)
        do { let state = try open(path); try state.expire(now: Date().addingTimeInterval(6 * 86400)); XCTAssertTrue(try state.isProvenNotApplied(nonce)); XCTAssertFalse(try state.execution(nonce)!.detailsAvailable); try state.verifyAudit() }
        let state = try open(path), broker = ReminderBroker(state: state, backend: ReminderUnenteredFixture())
        XCTAssertEqual(try call(broker, "commit_reminder_create", .object(["preview": preview]))["state"], .string("not_applied")); XCTAssertTrue(try state.isProvenNotApplied(nonce))
    }
    func testTamperedMinimalProofAndAuditSequenceRejectStartup() throws {
        for key in ["nonce", "state", "audit_sequence", "extra"] {
            let path = try directory(), (nonce, _) = try prepare(path, proof: true)
            do {
                let state = try open(path), old = try state.execution(nonce)!, raw = try state.rows("SELECT key FROM execution_keys WHERE nonce=?", [nonce])[0][0]
                var result = old.result.object!; result[key] = key == "audit_sequence" ? .int(999) : .string("changed")
                let value = JSON.object(result)
                try state.execute("UPDATE details SET result_cipher=? WHERE nonce=?", [try state.crypt(value, key: Data(base64Encoded: raw)!, nonce: nonce, field: "result_cipher"), nonce])
                try state.execute("UPDATE executions SET result=? WHERE nonce=?", [try value.text(), nonce])
            }
            XCTAssertThrowsError(try open(path), key)
        }
    }
    func testMarkerNativeAndCutoffTamperFailsAfterDetailsExpire() throws {
        for key in ["native_ids", "identity_cutoff", "source_nonces"] {
            let path = try directory(), (nonce, _) = try prepare(path, proof: true)
            do {
                let state = try open(path); try state.expire(now: Date().addingTimeInterval(6 * 86400))
                var marker = try state.execution(nonce)!.marker.object!
                if key == "native_ids" { marker[key] = .array([.string("changed-native")]) }
                else if key == "identity_cutoff" { marker[key] = .int(0) }
                else { marker[key] = .array([.string(nonce), .string(UUID().uuidString)]) }
                try state.execute("DROP TRIGGER execution_immutable"); try state.execute("UPDATE executions SET marker=? WHERE nonce=?", [try JSON.object(marker).text(), nonce])
            }
            XCTAssertThrowsError(try open(path), key)
        }
    }
    func testInterruptedIntentBecomesUnknownAndIsPinned() throws {
        let path = try directory(), (nonce, _) = try prepare(path, proof: false)
        let state = try open(path); XCTAssertEqual(try state.execution(nonce)!.state, "unknown")
        try state.expire(now: Date().addingTimeInterval(366 * 86400)); XCTAssertTrue(try state.execution(nonce)!.detailsAvailable); try state.verifyAudit()
    }
    func testUnresolvedExpiredDetailsRejectBeforeMaintenance() throws {
        let path = try directory(), (nonce, _) = try prepare(path, proof: false)
        do { let state = try open(path); try state.setMetadata("expiring_nonce", nonce); try state.execute("DELETE FROM execution_keys WHERE nonce=?", [nonce]); try state.setMetadata("expiring_nonce", ""); try state.execute("UPDATE details SET expired=1 WHERE nonce=?", [nonce]) }
        XCTAssertThrowsError(try open(path))
    }
    func testWrongDomainRefusedBeforeAnyDatabaseMutation() throws {
        let path = try directory(); do { let state = try open(path); try state.setMetadata("domain", "calendar") }
        let file = path.appendingPathComponent("reminders.sqlite3"), bytes = try Data(contentsOf: file)
        XCTAssertThrowsError(try open(path)); XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testSymlinkHardlinkUnsafeModesAndConcurrentOwnerRefuse() throws {
        let path = try directory(), child = path.appendingPathComponent("child")
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: path); XCTAssertThrowsError(try open(child))
        let safe = path.appendingPathComponent("safe"); let owner = try open(safe); XCTAssertThrowsError(try open(safe))
        withExtendedLifetime(owner) { }
        let hard = path.appendingPathComponent("hard"); try FileManager.default.createDirectory(at: hard, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); try FileManager.default.linkItem(at: safe.appendingPathComponent("reminders.sqlite3"), to: hard.appendingPathComponent("reminders.sqlite3")); XCTAssertThrowsError(try open(hard))
    }
    func testObservationCheckpointsKeepExactBoundedCounts() throws {
        let state = try open(directory()), start = Date()
        try state.recordObservation(replayed: false, operation: "commit_reminder_create", now: start)
        try state.recordObservation(replayed: true, operation: "commit_reminder_create", now: start.addingTimeInterval(3601))
        let body = try JSON.parse(Data(state.rows("SELECT body FROM audit WHERE body LIKE '%observation_checkpoint%'")[0][0].utf8))
        XCTAssertEqual(body["payload"]["observations"], .array([.object(["bucket": .string("rejected:create"), "count": .string("1")]), .object(["bucket": .string("replayed:create"), "count": .string("1")])]))
        XCTAssertEqual(try state.rows("SELECT count,checkpointed FROM observations ORDER BY bucket"), [["1", "1"], ["1", "1"]]); try state.verifyAudit()
        try state.execute("UPDATE observations SET checkpointed=count+1"); XCTAssertThrowsError(try state.verifyAudit())
    }
    func testAssessmentReceiptCorruptionRefusesStartup() throws {
        let path = try directory(), (nonce, _) = try prepare(path, proof: false)
        do {
            let state = try open(path), broker = ReminderBroker(state: state, backend: ReminderUnenteredFixture())
            let preview = try call(broker, "preflight_reminder_reconciliation", .object(["change_id": .string(nonce), "outcome": .string("applied"), "evidence": .string("Explicit synthetic assessment")]))["preview"]
            _ = try call(broker, "commit_reminder_reconciliation", .object(["preview": preview])); try state.verifyAudit()
            var receipt = try JSON.parse(Data(state.rows("SELECT receipt FROM assessments")[0][0].utf8)).object!; receipt["outcome"] = .string("not_applied")
            try state.execute("DROP TRIGGER assessment_no_update"); try state.execute("UPDATE assessments SET receipt=?", [try JSON.object(receipt).text()])
        }
        XCTAssertThrowsError(try open(path))
    }
    func testTerminalPersistenceFailureNeverReturnsNonblockingOutcome() throws {
        let state = try open(directory()), broker = ReminderBroker(state: state, backend: ReminderUnenteredFixture()), p = try createPreview(broker)
        try state.execute("CREATE TRIGGER fixture_outcome_failure BEFORE UPDATE OF state ON executions BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        let result = try call(broker, "commit_reminder_create", .object(["preview": p]))
        XCTAssertEqual(result["state"], .string("unknown")); XCTAssertEqual(result["diagnostic"]["stage"], .string("outcome_persistence")); XCTAssertEqual(try state.execution(p["envelope"]["nonce"].string!)!.state, "intent_recorded")
        XCTAssertFalse(try state.isProvenNotApplied(p["envelope"]["nonce"].string!))
    }
    func testWireExpansionBudgetsCoverDELAndUnicode() throws {
        let state = try open(directory()), broker = ReminderBroker(state: state, backend: ReminderUnenteredFixture())
        for (text, bound) in [("\u{7f}", 6), ("é", 6), ("😀", 12)] {
            let value = JSON.string(String(repeating: text, count: 100)); XCTAssertNoThrow(try broker.budget(value, utf8: 1000, ascii: 100 * bound + 2)); XCTAssertThrowsError(try broker.budget(value, utf8: 1000, ascii: 100 * bound + 1))
        }
    }
    func testFilteredHistoryPagesAcrossMultipleBoundedChunks() throws {
        let state = try open(directory()), broker = ReminderBroker(state: state, backend: ReminderUnenteredFixture()), preview = try createPreview(broker)
        try state.transaction {
            for index in 0..<270 {
                let nonce = UUID().uuidString; var envelope = preview["envelope"].object!; envelope["nonce"] = .string(nonce)
                let payload = JSON.object(envelope), marker = try state.reminderMarker(payload, nonce: nonce), key = Data(repeating: UInt8(index % 255), count: 32), time = Date(), outcome = index < 5 ? "unknown" : "applied"
                let intent: JSON = .object(["nonce": .string(nonce), "state": .string("intent_recorded"), "action": .string("create")])
                try state.execute("INSERT INTO execution_keys VALUES(?,?)", [nonce, key.base64EncodedString()])
                try state.execute("INSERT INTO details VALUES(?,?,?,?,?,0)", [nonce, try state.crypt(payload, key: key, nonce: nonce, field: "payload_cipher"), try state.crypt(intent, key: key, nonce: nonce, field: "result_cipher"), iso(time), iso(time.addingTimeInterval(86400))])
                try state.execute("INSERT INTO executions VALUES(?,?,?,?,?,?)", [nonce, try marker.text(), "intent_recorded", try intent.text(), iso(time), ""])
                let sequence = try state.appendInside("write_intent", nonce: nonce, payload: marker)
                let result: JSON = .object(["nonce": .string(nonce), "state": .string(outcome), "action": .string("create"), "audit_sequence": .int(sequence)])
                try state.execute("UPDATE details SET result_cipher=? WHERE nonce=?", [try state.crypt(result, key: key, nonce: nonce, field: "result_cipher"), nonce])
                try state.execute("UPDATE executions SET state=?,result=? WHERE nonce=?", [outcome, try result.text(), nonce]); _ = try state.appendInside(outcome == "applied" ? "write_applied" : "write_unknown", nonce: nonce, payload: result)
            }
        }
        var cursor: JSON = .null, seen: Set<String> = [], pages: [Int] = []
        repeat {
            var args: [String: JSON] = ["limit": .int(2), "state": .string("unknown")]; if cursor != .null { args["cursor"] = cursor }
            let page = try call(broker, "list_reminder_changes", .object(args)), changes = page["changes"].array!; pages.append(changes.count)
            for change in changes { XCTAssertTrue(seen.insert(change["change_id"].string!).inserted) }; cursor = page["next_cursor"]
        } while cursor != .null
        XCTAssertEqual(pages, [2, 2, 1]); XCTAssertEqual(seen.count, 5); try state.verifyAudit()
    }

    func testFailedInitializationReleasesLockAndDatabaseForRepair() throws {
        let path = try directory(); do { let state = try open(path); try state.setMetadata("domain", "wrong-resource") }
        for _ in 0..<3 { XCTAssertThrowsError(try open(path)) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.appendingPathComponent("reminders.sqlite3").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE metadata SET value='reminders' WHERE key='domain'", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        do { let owner = try open(path); for _ in 0..<3 { XCTAssertThrowsError(try open(path)) }; withExtendedLifetime(owner) { } }
        XCTAssertNoThrow(try open(path))
    }

}
