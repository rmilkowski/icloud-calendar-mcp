import XCTest
import Foundation
import CSQLite
import CryptoKit
import Darwin
@testable import CalendarCore

private final class RecoveryClock { var value = try! parseDate("2026-10-24T12:00:00Z") }

final class RecoveryTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() { for dir in directories { try? FileManager.default.removeItem(at: dir) }; super.tearDown() }
    private func directory() -> URL { let dir = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-recovery-test-" + UUID().uuidString); directories.append(dir); return dir }
    private func store(_ dir: URL) throws -> StateStore { let state = try StateStore(directory: dir); try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "b", count: 64)); return state }
    private func fixture(_ count: Int = 1, details: JSON = .object([:])) -> SyntheticBackend {
        SyntheticBackend(events: (0..<count).map { EventRecord(nativeID: "fixture-\($0)", calendarNativeID: "synthetic-calendar", fields: EventFields(title: "Private retained fixture \($0)", start: "2026-10-25T10:00:00Z", end: "2026-10-25T11:00:00Z", timeZone: "Europe/London", allDay: false, notes: "Private fixture notes"), details: details) })
    }
    private func call(_ broker: Broker, _ op: String, _ args: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(op), "arguments": .object(args)])) }
    private func ids(_ broker: Broker) -> [JSON] { call(broker, "query_events", ["start": .string("2026-10-25T00:00:00Z"), "end": .string("2026-10-26T00:00:00Z")])["result"]["events"].array!.map { $0["id"] } }
    private func change(_ broker: Broker, _ id: JSON, action: String = "modify", title: String = "Modified fixture") -> JSON {
        var args: [String: JSON] = ["action": .string(action), "scope": .string("this"), "event_id": id]
        if action == "modify" { args["fields"] = .object(["title": .string(title)]) }
        let draft = call(broker, "preflight_change", args)
        return call(broker, "commit_" + action, ["preview": draft["result"]["preview"]])
    }
    private func plan(_ broker: Broker, _ changes: [JSON]) -> JSON { call(broker, "preflight_rollback", ["change_ids": .array(changes)]) }
    private func step(_ response: JSON) -> JSON { response["result"]["steps"].array!.first!["preview"] }
    private func undo(_ broker: Broker, _ preview: JSON) -> JSON { call(broker, "commit_rollback", ["preview": preview]) }
    private func scalar(_ dir: URL, _ statement: String) throws -> String {
        var db: OpaquePointer?, query: OpaquePointer?; XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("state.sqlite3").path, &db), SQLITE_OK); defer { sqlite3_finalize(query); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, statement, -1, &query, nil), SQLITE_OK)
        guard sqlite3_step(query) == SQLITE_ROW else { return "" }; return sqlite3_column_text(query, 0).map { String(cString: $0) } ?? ""
    }
    private func sql(_ dir: URL, _ statement: String) throws {
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("state.sqlite3").path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw CoreError("test_sql", "Synthetic migration fixture SQL failed") }
    }
    private func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

    func testLegacyMigrationEncryptsEvidenceBindsOriginalAuditAndResumesCleanup() throws {
        let dir = directory(), backend = fixture(), clock = RecoveryClock(), nonce: String, payload: JSON, result: JSON
        do {
            let state = try store(dir), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0]
            let applied = change(broker, id); nonce = applied["result"]["nonce"].string!
            payload = try state.execution(nonce)!.payload
            result = .object(["nonce": .string(nonce), "state": .string("reconciled"), "outcome": .string("not_applied"), "evidence": .string("Legacy private operator evidence"), "previous_result": applied["result"]])
        }
        let oldBody: JSON = .object(["version": .int(1), "sequence": .int(1), "event_id": .string(UUID().uuidString), "timestamp": .string(iso(clock.value)), "event": .string("operator_reconciliation"), "nonce": .string(nonce), "approval_source": .string("local_operator_attestation"), "approval_evidence": .string("not_provided"), "payload": result])
        let zero = String(repeating: "0", count: 64), bodyText = try oldBody.text(), tail = digest(Data(zero.utf8) + Data(bodyText.utf8))
        try sql(dir, "DROP TRIGGER payload_immutable; DROP TRIGGER execution_v2_insert; DROP TRIGGER execution_v2_result; DROP TRIGGER audit_no_delete; DELETE FROM audit; DELETE FROM execution_details; DELETE FROM execution_keys; DELETE FROM legacy_audit_manifest; DELETE FROM legacy_audit_details; DELETE FROM metadata WHERE key IN ('recovery_storage_version','recovery_cleanup_pending'); UPDATE executions SET payload=\(quoted(try payload.text())),state='reconciled',result=\(quoted(try result.text())) WHERE nonce=\(quoted(nonce)); INSERT INTO audit VALUES(1,\(quoted(bodyText)),\(quoted(zero)),\(quoted(tail)))")
        do {
            let state = try store(dir), migrated = try state.execution(nonce)!
            XCTAssertEqual(migrated.payload, payload); XCTAssertEqual(migrated.result, result)
            let checkpoint = try state.auditRecords().first!
            XCTAssertEqual(checkpoint["event"], .string("recovery_migration_checkpoint")); XCTAssertEqual(checkpoint["payload"]["legacy_tail_hash"], .string(tail))
            XCTAssertEqual(checkpoint["payload"]["legacy_record_count"], .int(1))
            XCTAssertEqual(try scalar(dir, "SELECT count(*) FROM legacy_audit_details"), "1")
            let key = Data(base64Encoded: try scalar(dir, "SELECT key FROM execution_keys"))!, ciphertext = Data(base64Encoded: try scalar(dir, "SELECT cipher FROM legacy_audit_details"))!
            let decrypted = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: key), authenticating: Data((nonce + ":legacy_audit_1").utf8))
            XCTAssertEqual(try JSON.parse(decrypted), oldBody)
            XCTAssertFalse(String(decoding: try Data(contentsOf: dir.appendingPathComponent("state.sqlite3")), as: UTF8.self).contains("Legacy private operator evidence"))
            XCTAssertEqual(try state.metadata("recovery_cleanup_pending"), "false"); try state.verifyAudit()
        }
        // A crash after migration commit but before scrub completion must retry cleanup.
        try sql(dir, "UPDATE metadata SET value='true' WHERE key='recovery_cleanup_pending'")
        do { let state = try store(dir); XCTAssertEqual(try state.metadata("recovery_cleanup_pending"), "false"); try state.verifyAudit() }
        try sql(dir, "UPDATE legacy_audit_manifest SET body='{}'")
        XCTAssertThrowsError(try store(dir))
    }

    func testOldHelperStartupRejectsV2BeforeLogicalStateChanges() throws {
        let legacyPath = ProcessInfo.processInfo.environment["CALENDAR_LEGACY_HELPER"] ?? "/private/tmp/calendar-bulk-safety-build/debug/CalendarHelper"
        guard FileManager.default.isExecutableFile(atPath: legacyPath) else { throw XCTSkip("Set CALENDAR_LEGACY_HELPER to the frozen v1 helper for the downgrade process test") }
        let dir = directory()
        do { _ = try store(dir) }
        let before = try scalar(dir, "SELECT group_concat(key || ':' || value, '|') FROM (SELECT key,value FROM metadata ORDER BY key)")
        let auditBefore = try scalar(dir, "SELECT group_concat(hash, '|') FROM audit")
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: legacyPath); process.arguments = ["--serve", "--state-dir", dir.path, "--backend", "synthetic", "--credential-binding", String(repeating: "c", count: 64)]; process.standardInput = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        let response = try JSON.parse(output.fileHandleForReading.readDataToEndOfFile())
        XCTAssertNotEqual(process.terminationStatus, 0); XCTAssertEqual(response["error"]["code"], .string("audit_corrupt"))
        XCTAssertEqual(try scalar(dir, "SELECT group_concat(key || ':' || value, '|') FROM (SELECT key,value FROM metadata ORDER BY key)"), before)
        XCTAssertEqual(try scalar(dir, "SELECT group_concat(hash, '|') FROM audit"), auditBefore)
        XCTAssertEqual(try scalar(dir, "SELECT count(*) FROM executions"), "0")
    }

    func testSuffixGroupingAndOlderUndoAfterVerifiedNewIdentitySnapshot() throws {
        let state = try store(directory()), backend = fixture(), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0]
        let first = change(broker, id, title: "First"), second = change(broker, id, title: "Second")
        XCTAssertEqual(plan(broker, [first["result"]["nonce"]])["error"]["code"], .string("rollback_lineage"))
        let latestPreview = step(plan(broker, [second["result"]["nonce"]]))
        XCTAssertEqual(undo(broker, latestPreview)["result"]["state"], .string("applied")); XCTAssertEqual(backend.events[0].fields.title, "First")
        let earlier = step(plan(broker, [first["result"]["nonce"]]))
        XCTAssertEqual(undo(broker, earlier)["result"]["state"], .string("applied")); XCTAssertEqual(backend.events[0].fields.title, "Private retained fixture 0")
        XCTAssertEqual(plan(broker, [first["result"]["nonce"]])["error"]["code"], .string("rollback_ineligible"))
        XCTAssertEqual(undo(broker, latestPreview)["result"]["state"], .string("applied")); XCTAssertEqual(backend.writeCount, 4)
    }

    func testGroupCollapsesModifyThenDeleteAndRestoresDetailsWithSameOpaqueID() throws {
        let extras: JSON = .object(["url": .string("https://example.invalid/private-fixture"), "alarms": .array([.object(["absolute_date": .null, "relative_offset": .string("-300.0"), "proximity": .int(0), "structured_location": .null, "type": .int(0), "email_address": .null, "sound_name": .null])]), "structured_location": .object(["title": .string("Fixture"), "radius": .string("0.0"), "latitude": .string("51.5"), "longitude": .string("-0.1")])])
        let state = try store(directory()), backend = fixture(details: extras), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0], originalNative = backend.events[0].nativeID
        let modified = change(broker, id), deleted = change(broker, id, action: "delete")
        let draft = plan(broker, [modified["result"]["nonce"], deleted["result"]["nonce"]]); XCTAssertEqual(draft["result"]["step_count"], .int(1))
        let preview = step(draft); XCTAssertEqual(preview["envelope"]["action"], .string("create"))
        XCTAssertEqual(call(broker, "commit_create", ["preview": preview])["error"]["code"], .string("invalid_arguments"))
        let result = undo(broker, preview); XCTAssertEqual(result["result"]["state"], .string("applied")); XCTAssertEqual(result["result"]["event"]["id"], id)
        XCTAssertNotEqual(backend.events[0].nativeID, originalNative); XCTAssertEqual(backend.events[0].details, extras)
        XCTAssertEqual(backend.events[0].fields.title, "Private retained fixture 0")
        XCTAssertEqual(call(broker, "get_event", ["event_id": id])["result"]["event"]["id"], id)
    }

    func testExternalEditAndNewIntegrationChangeInvalidateRollbackBeforeIntent() throws {
        let state = try store(directory()), backend = fixture(), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0]
        let modified = change(broker, id), preview = step(plan(broker, [modified["result"]["nonce"]]))
        backend.events[0].fields.notes = "External fixture edit"
        XCTAssertEqual(undo(broker, preview)["error"]["code"], .string("stale_event")); XCTAssertEqual(backend.writeCount, 1)
        XCTAssertNil(try state.execution(preview["envelope"]["nonce"].string!))
        _ = change(broker, id, title: "Newer change")
        XCTAssertEqual(undo(broker, preview)["error"]["code"], .string("rollback_lineage")); XCTAssertEqual(backend.writeCount, 2)
    }

    func testExternalEditBetweenIntegrationChangesCannotBeErasedByGroupedOrSequentialUndo() throws {
        let state = try store(directory()), backend = fixture(), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0]
        let first = change(broker, id, title: "A integration title")
        backend.events[0].fields.notes = "External notes that must survive"
        let second = change(broker, id, title: "B integration title")
        XCTAssertEqual(plan(broker, [first["result"]["nonce"], second["result"]["nonce"]])["error"]["code"], .string("rollback_history_gap"))
        XCTAssertEqual(backend.writeCount, 2)
        XCTAssertEqual(undo(broker, step(plan(broker, [second["result"]["nonce"]])))["result"]["state"], .string("applied"))
        XCTAssertEqual(backend.events[0].fields.title, "A integration title"); XCTAssertEqual(backend.events[0].fields.notes, "External notes that must survive")
        XCTAssertEqual(plan(broker, [first["result"]["nonce"]])["error"]["code"], .string("rollback_history_gap"))
        XCTAssertEqual(backend.events[0].fields.notes, "External notes that must survive"); XCTAssertEqual(backend.writeCount, 3)
    }

    func testExpiredHistoricalBridgeBlocksEarlierUndoEvenWhenEarlierSourceRetained() throws {
        let dir = directory(), state = try store(dir), backend = fixture(), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0], policy = dir.appendingPathComponent("recovery-policy.json")
        let first = change(broker, id, title: "A")
        try Data("{\"version\":1,\"retention_days\":1}".utf8).write(to: policy); XCTAssertEqual(chmod(policy.path, 0o600), 0)
        let second = change(broker, id, title: "B")
        XCTAssertEqual(undo(broker, step(plan(broker, [second["result"]["nonce"]])))["result"]["state"], .string("applied"))
        clock.value.addTimeInterval(86400)
        XCTAssertEqual(plan(broker, [first["result"]["nonce"]])["error"]["code"], .string("rollback_history_gap"))
        XCTAssertEqual(backend.events[0].fields.title, "A"); XCTAssertEqual(backend.writeCount, 3)
    }

    func testEncryptedDetailsExpireIrreversiblyWhileReplayAndQuotaRemain() throws {
        let dir = directory(), backend = fixture(), clock = RecoveryClock(), preview: JSON, nonce: String
        do {
            let state = try store(dir), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0]
            let draft = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("this"), "event_id": id, "fields": .object(["title": .string("Secret replacement title")])]); preview = draft["result"]["preview"]
            nonce = changeNonce(call(broker, "commit_modify", ["preview": preview]))
            let raw = try Data(contentsOf: dir.appendingPathComponent("state.sqlite3")); XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("Private retained fixture")); XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("Secret replacement title"))
            clock.value.addTimeInterval(5 * 86400)
            XCTAssertEqual(call(broker, "get_stored_change", ["change_id": .string(nonce)])["result"]["before"], .null)
            XCTAssertEqual(try scalar(dir, "SELECT count(*) FROM execution_keys"), "0")
            let replay = call(broker, "commit_modify", ["preview": preview]); XCTAssertEqual(replay["result"]["state"], .string("applied")); XCTAssertEqual(replay["result"]["details_expired"], .bool(true)); XCTAssertEqual(backend.writeCount, 1)
            XCTAssertEqual(try scalar(dir, "SELECT count(*) FROM write_safety_claims"), "1")
        }
        clock.value.addTimeInterval(-4 * 86400)
        let state = try store(dir), broker = Broker(state: state, backend: backend, now: { clock.value })
        XCTAssertEqual(call(broker, "get_stored_change", ["change_id": .string(nonce)])["result"]["before"], .null)
        XCTAssertEqual(try scalar(dir, "SELECT count(*) FROM execution_keys"), "0"); try state.verifyAudit()
    }
    private func changeNonce(_ result: JSON) -> String { XCTAssertEqual(result["result"]["state"], .string("applied")); return result["result"]["nonce"].string! }

    func testUnknownRollbackPinsOriginalEvidencePastExpiryAndBlocksWrites() throws {
        let dir = directory(), state = try store(dir), backend = fixture(), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0]
        let original = change(broker, id), preview = step(plan(broker, [original["result"]["nonce"]]))
        backend.throwAfterWrite = true
        XCTAssertEqual(undo(broker, preview)["result"]["state"], .string("unknown"))
        clock.value.addTimeInterval(6 * 86400)
        _ = broker.maintainRecoveryDetails()
        XCTAssertEqual(try scalar(dir, "SELECT count(*) FROM execution_keys"), "2")
        XCTAssertNotEqual(call(broker, "get_stored_change", ["change_id": original["result"]["nonce"]])["result"]["before"], .null)
        let listed = call(broker, "list_changes")["result"]["changes"].array!
        XCTAssertEqual(listed.count, 1); XCTAssertEqual(listed[0]["retention_hold"], .bool(true))
        XCTAssertEqual(plan(broker, [original["result"]["nonce"]])["error"]["code"], .string("unresolved_write")); XCTAssertEqual(backend.writeCount, 2)
    }

    func testLocalReviewAuditSourceCannotBeChosenThroughNDJSON() throws {
        let state = try store(directory()), backend = fixture(), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0]
        let original = change(broker, id), preview = step(plan(broker, [original["result"]["nonce"]]))
        XCTAssertEqual(call(broker, "commit_rollback", ["preview": preview, "local_native_ui": .bool(true)])["error"]["code"], .string("invalid_arguments"))
        let localResult = broker.commitReviewedRollback(preview)
        XCTAssertEqual(localResult["result"]["state"], .string("applied"))
        let audit = try state.auditRecords().last!; XCTAssertEqual(audit["approval_source"], .string("local_native_ui")); XCTAssertEqual(audit["approval_evidence"], .string("native_control_activated"))
        XCTAssertEqual(audit["payload"]["detail_digest"], .string(digest(try localResult["result"].data())))
        clock.value.addTimeInterval(6 * 86400)
        _ = broker.commitReviewedRollback(preview)
        XCTAssertTrue(try state.auditRecords().filter { $0["event"] == .string("details_expired") }.allSatisfy { $0["approval_source"] == .string("native_maintenance") && $0["approval_evidence"] == .string("not_provided") })
        XCTAssertEqual(audit["payload"]["event"], .null); XCTAssertEqual(audit["sequence"], .null); XCTAssertNotNil(audit["record_sequence"].integer)
    }

    func testPaginationFreezesInventoryAndBindsFilters() throws {
        let state = try store(directory()), backend = fixture(3), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), events = ids(broker)
        for id in events { _ = change(broker, id) }
        let first = call(broker, "list_changes", ["limit": .int(1)]), cursor = first["result"]["next_cursor"]
        _ = change(broker, events[0], title: "New after cursor")
        let second = call(broker, "list_changes", ["limit": .int(100), "cursor": cursor])
        XCTAssertEqual(second["result"]["changes"].array?.count, 2)
        XCTAssertEqual(call(broker, "list_changes", ["action": .string("delete"), "cursor": cursor])["error"]["code"], .string("invalid_cursor"))
        clock.value.addTimeInterval(6 * 86400)
        XCTAssertEqual(call(broker, "list_changes", ["limit": .int(100), "cursor": cursor])["result"]["changes"].array?.count, 2)
    }

    func testAllOverTwentyFiveRejectsAndRecurringDeleteCreatesNoIntent() throws {
        let state = try store(directory()), backend = fixture(26), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), events = ids(broker)
        for id in events { _ = change(broker, id) }
        XCTAssertEqual(call(broker, "preflight_rollback", ["all": .bool(true)])["error"]["code"], .string("selection_too_large"))
        backend.events[0].recurring = true; backend.events[0].occurrence = "2026-10-25T10:00:00.000Z"
        let id = call(broker, "query_events", ["start": .string("2026-10-25T00:00:00Z"), "end": .string("2026-10-26T00:00:00Z")])["result"]["events"].array!.first { $0["recurring"] == .bool(true) }!["id"]
        XCTAssertEqual(call(broker, "preflight_change", ["action": .string("delete"), "scope": .string("this"), "event_id": id])["error"]["code"], .string("unsupported_restore"))
        XCTAssertEqual(backend.writeCount, 26)
    }

    func testPreviouslySignedUnsupportedDeleteIsRejectedAtCommitBeforeIntent() throws {
        let state = try store(directory()), backend = fixture(), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value })
        backend.events[0].recurring = true; backend.events[0].occurrence = "2026-10-25T10:00:00.000Z"
        let before = call(broker, "query_events", ["start": .string("2026-10-25T00:00:00Z"), "end": .string("2026-10-26T00:00:00Z")])["result"]["events"].array!.first!
        let envelope: JSON = .object(["version": .int(1), "nonce": .string(UUID().uuidString), "issued_at": .string(iso(clock.value)), "expires_at": .string(iso(clock.value.addingTimeInterval(600))), "installation_id": .string(try state.metadata("installation_id")!), "credential_generation": .string(try state.metadata("credential_generation")!), "key_id": .string(try state.metadata("key_id")!), "action": .string("delete"), "scope": .string("this"), "calendar": before["calendar"], "before": before, "after": .null])
        let key = SymmetricKey(data: Data(base64Encoded: try state.metadata("signing_key")!)!), tag = HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: key)
        let preview: JSON = .object(["envelope": envelope, "authentication_tag": .string(Data(tag).base64EncodedString())])
        XCTAssertEqual(call(broker, "commit_delete", ["preview": preview])["error"]["code"], .string("unsupported_restore"))
        XCTAssertNil(try state.execution(envelope["nonce"].string!)); XCTAssertEqual(backend.writeCount, 0)
    }

    func testRecurringModificationRollbackDisclosesPreservedCurrentSeriesStructure() throws {
        let state = try store(directory()), backend = fixture(), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value })
        backend.events[0].recurring = true; backend.events[0].occurrence = "2026-10-25T10:00:00.000Z"
        let id = ids(broker)[0], original = change(broker, id)
        let preview = step(plan(broker, [original["result"]["nonce"]]))
        XCTAssertTrue(preview["envelope"]["rollback"]["limitations"].array!.contains { $0.string?.contains("Historical detachment and series membership are not restored") == true })
        XCTAssertEqual(undo(broker, preview)["result"]["state"], .string("applied")); XCTAssertTrue(backend.events[0].recurring)
    }

    func testUnsupportedAlarmRestorationIsRejectedBeforeAnyDeletion() throws {
        let state = try store(directory()), backend = fixture(details: .object(["alarms": .array([.object(["absolute_date": .null, "relative_offset": .string("-300"), "proximity": .int(0), "structured_location": .null, "type": .int(1), "email_address": .null, "sound_name": .null])])])), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0]
        XCTAssertEqual(call(broker, "preflight_change", ["action": .string("delete"), "scope": .string("this"), "event_id": id])["error"]["code"], .string("unsupported_restore"))
        XCTAssertEqual(backend.writeCount, 0)
    }

    func testNativeReviewGenerationRejectsInspectionSelectionAndStaleCallbacks() {
        var gate = NativeReviewGate()
        let initial = gate.generation
        XCTAssertTrue(gate.displayReview(generation: initial)); XCTAssertTrue(gate.canApply)
        gate.invalidate() // Inspect stored details or change selected rows.
        XCTAssertFalse(gate.canApply); XCTAssertFalse(gate.displayReview(generation: initial))
        let next = gate.generation; XCTAssertTrue(gate.displayReview(generation: next))
        gate.invalidate() // Window closed while an asynchronous preparation was running.
        XCTAssertFalse(gate.canApply); XCTAssertFalse(gate.displayReview(generation: next))
    }

    func testSocketEndpointUsesPOSIXCanonicalPathAndLegacyTitlesStayBounded() throws {
        let dir = directory(), state = try store(dir), backend = fixture(), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0]
        let canonical = realpath(dir.path, nil)!; defer { free(canonical) }
        let expected = "/private/tmp/calendar-mcp-ui-\(getuid())-" + String(digest(Data(String(cString: canonical).utf8)).prefix(20))
        XCTAssertEqual(try localRecoverySocketDirectory(stateDirectory: dir).path, expected)
        let ordinary = call(broker, "get_event", ["event_id": id])["result"]["event"], huge = String(repeating: "Legacy title 👩🏽‍💻", count: 4000)
        var before = ordinary.object!, fields = before["fields"]!.object!; fields["title"] = .string(huge); before["fields"] = .object(fields)
        let nonce = UUID().uuidString, payload: JSON = .object(["action": .string("delete"), "before": .object(before), "after": .null])
        _ = try state.claim(nonce: nonce, payload: payload, now: clock.value)
        try state.finish(nonce: nonce, state: "applied", result: .object(["state": .string("applied")]), event: "write_applied")
        let result = call(broker, "list_changes")["result"], summary = result["changes"].array!.first!
        XCTAssertEqual(summary["title_truncated"], .bool(true)); XCTAssertLessThanOrEqual(summary["title"].string!.unicodeScalars.count, 300)
        XCTAssertLessThan(try result.data().count, 10_000)
        XCTAssertEqual(call(broker, "get_stored_change", ["change_id": .string(nonce)])["result"]["before"]["fields"]["title"], .string(huge))
        XCTAssertEqual(try state.auditRecords().first!["approval_source"], .string("native_maintenance"))
    }

    func testRetentionPolicyIsStrictAndDoesNotExtendCapturedExpiry() throws {
        let dir = directory(), state = try store(dir), backend = fixture(), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0], path = dir.appendingPathComponent("recovery-policy.json")
        try Data("{\"version\":1,\"retention_days\":1}".utf8).write(to: path); XCTAssertEqual(chmod(path.path, 0o600), 0)
        let original = change(broker, id), nonce = original["result"]["nonce"]
        try Data("{\"version\":1,\"retention_days\":365}".utf8).write(to: path)
        clock.value.addTimeInterval(86400)
        XCTAssertEqual(call(broker, "get_stored_change", ["change_id": nonce])["result"]["change"]["details_expired"], .bool(true))
        try Data("{\"version\":1,\"retention_days\":true}".utf8).write(to: path)
        XCTAssertThrowsError(try state.recoveryPolicy())
        XCTAssertEqual(chmod(path.path, 0o644), 0); XCTAssertThrowsError(try state.recoveryPolicy())
    }

    func testNewDetailsAfterClockRollbackReceiveFullWindowWithoutResurrectingExpiredRows() throws {
        let dir = directory(), state = try store(dir), backend = fixture(), clock = RecoveryClock(), broker = Broker(state: state, backend: backend, now: { clock.value }), id = ids(broker)[0]
        let old = change(broker, id, title: "Old captured change")["result"]["nonce"]
        clock.value.addTimeInterval(10 * 86400); _ = broker.maintainRecoveryDetails()
        XCTAssertEqual(call(broker, "get_stored_change", ["change_id": old])["result"]["change"]["details_expired"], .bool(true))
        let highwater = clock.value; clock.value.addTimeInterval(-10 * 86400)
        let fresh = change(broker, id, title: "New change after clock rollback")["result"]["nonce"]
        _ = broker.maintainRecoveryDetails()
        XCTAssertEqual(call(broker, "get_stored_change", ["change_id": fresh])["result"]["change"]["details_expired"], .bool(false))
        XCTAssertEqual(try scalar(dir, "SELECT captured FROM execution_details WHERE nonce=\(quoted(fresh.string!))"), iso(highwater))
        XCTAssertEqual(try scalar(dir, "SELECT created FROM executions WHERE nonce=\(quoted(fresh.string!))"), iso(clock.value))
        clock.value = highwater.addingTimeInterval(5 * 86400 - 1); _ = broker.maintainRecoveryDetails()
        XCTAssertEqual(try scalar(dir, "SELECT count(*) FROM execution_keys"), "1")
        clock.value.addTimeInterval(1); _ = broker.maintainRecoveryDetails()
        XCTAssertEqual(try scalar(dir, "SELECT count(*) FROM execution_keys"), "0")
        XCTAssertEqual(call(broker, "get_stored_change", ["change_id": old])["result"]["change"]["details_expired"], .bool(true))
    }
}
