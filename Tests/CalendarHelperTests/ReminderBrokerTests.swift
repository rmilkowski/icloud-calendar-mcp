// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import Foundation
@testable import CalendarCore

private final class ReminderProbe: ReminderBackend {
    let base: SyntheticReminderBackend
    var mode = "success", returned = false
    var entries = 0
    init(_ base: SyntheticReminderBackend) { self.base = base }
    func lists() throws -> [ReminderListRecord] { try base.lists() }
    func query(listID: String) throws -> [ReminderRecord] { try base.query(listID: listID) }
    func get(nativeID: String, listID: String) throws -> ReminderRecord {
        if returned && mode == "typed_readback" { return try ProviderMutationAttempt.run { _ in throw CoreError("stale_event", "Private later-read fixture") } }
        return try base.get(nativeID: nativeID, listID: listID)
    }
    func apply(action: String, listID: String, existing: ReminderRecord?, fields: ReminderFields?, completed: Bool?, changedFields: [String], completionPolicy: String, completionDate: Date?, restoration: JSON?) throws -> ReminderWriteResult {
        if mode == "untyped" { throw NSError(domain: "PrivateFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Private credential fixture"]) }
        let result = try ProviderMutationAttempt.run { attempt in
            if mode == "before" { throw CoreError("read_only", "Private reminder text") }
            return try attempt.mutate {
                entries += 1
                if mode == "entered" { throw NSError(domain: "PrivateFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Private credential fixture"]) }
                let result = try base.apply(action: action, listID: listID, existing: existing, fields: fields, completed: completed, changedFields: changedFields, completionPolicy: completionPolicy, completionDate: completionDate, restoration: restoration)
                if mode == "after" { attempt.reading(.providerRefresh); throw CoreError("verification_failed", "Private refresh fixture") }
                if mode == "new_id", var value = result.record {
                    base.records.removeAll { $0.nativeID == value.nativeID }; value.nativeID = UUID().uuidString; base.records.append(value)
                    return ReminderWriteResult(record: value, completionDate: result.completionDate)
                }
                return result
            }
        }
        returned = true; return result
    }
}

final class ReminderBrokerTests: XCTestCase {
    let binding = String(repeating: "a", count: 64)
    func directory() throws -> URL { let value = FileManager.default.temporaryDirectory.appendingPathComponent("reminders-test-" + UUID().uuidString); try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); addTeardownBlock { try? FileManager.default.removeItem(at: value) }; return value }
    func fields(_ title: String = "Synthetic reminder") throws -> ReminderFields { try ReminderFields(.object(["title": .string(title), "notes": .string(""), "priority": .int(0), "start": .null, "due": .null])) }
    func record(_ id: String = "first", list: String = "list-a", completed: Bool = false) throws -> ReminderRecord {
        let date = completed ? Date(timeIntervalSinceReferenceDate: 800000000.1234567) : nil
        return ReminderRecord(nativeID: id, listNativeID: list, fields: try fields(), completed: completed, completionDate: date.map(iso), details: .object(["start_components": .null, "due_components": .null, "completion_date_reference": date.map { .string(String($0.timeIntervalSinceReferenceDate.bitPattern)) } ?? .null, "alarms": .array([]), "has_recurrence_rules": .bool(false), "recurrence_rules": .array([]), "url": .null, "location": .null, "structured_location": .null, "attendees": .array([]), "item_time_zone": .null]))
    }
    fileprivate func fixture(completed: Bool = false) throws -> (ReminderStateStore, SyntheticReminderBackend, ReminderProbe, ReminderBroker) {
        let state = try ReminderStateStore(directory: directory(), backendMode: "synthetic", credentialBinding: binding)
        let base = SyntheticReminderBackend(lists: [ReminderListRecord(nativeID: "list-a", title: "First", source: "Synthetic"), ReminderListRecord(nativeID: "list-b", title: "Second", source: "Synthetic")], reminders: [try record(completed: completed), try record("second"), try record("third", list: "list-b")])
        let probe = ReminderProbe(base); return (state, base, probe, ReminderBroker(state: state, backend: probe))
    }
    func call(_ broker: ReminderBroker, _ op: String, _ args: JSON = .object([:])) throws -> JSON {
        let result = broker.handle(.object(["op": .string(op), "arguments": args]))
        if result["error"] != .null { throw CoreError(result["error"]["code"].string ?? "test_error", result["error"]["message"].string ?? "Fixture failed") }; return result["result"]
    }
    func ids(_ broker: ReminderBroker) throws -> (String, [String]) {
        let lists = try call(broker, "list_reminder_lists")["lists"].array!, list = lists.first { $0["title"] == .string("First") }!["id"].string!
        let page = try call(broker, "query_reminders", .object(["list_id": .string(list), "status": .string("all"), "limit": .int(100)]))
        XCTAssertEqual(page["truncated"], .bool(false))
        let records = page["reminders"].array!
        let ordered = try records.sorted { try broker.state.resolve($0["id"].string!, kind: "reminder").nativeID < broker.state.resolve($1["id"].string!, kind: "reminder").nativeID }
        return (list, ordered.compactMap { $0["id"].string })
    }
    func preview(_ broker: ReminderBroker, action: String, id: String, list: String) throws -> JSON {
        var args: [String: JSON] = ["action": .string(action), "scope": .string("this")]
        if action == "create" { args["list_id"] = .string(list); args["fields"] = .object(["title": .string("Created synthetic reminder")]) }
        else { args["reminder_id"] = .string(id); if action == "modify" { args["fields"] = .object(["title": .string("Changed synthetic reminder")]) } }
        return try call(broker, "preflight_reminder_change", .object(args))["preview"]
    }
    func commit(_ broker: ReminderBroker, _ preview: JSON, rollback: Bool = false) throws -> JSON { try call(broker, rollback ? "commit_reminder_rollback" : "commit_reminder_" + preview["envelope"]["action"].string!, .object(["preview": preview])) }
    func inverse(_ broker: ReminderBroker, _ result: JSON) throws -> JSON { try call(broker, "preflight_reminder_rollback", .object(["change_id": result["nonce"]]))["steps"].array![0]["preview"] }
    func testAllActionsAndSingleSourceInversesReplayExactly() throws {
        for action in ["create", "modify", "complete", "reopen", "delete"] {
            let (state, base, _, broker) = try fixture(completed: action == "reopen"), (list, targets) = try ids(broker)
            let p = try preview(broker, action: action, id: targets[0], list: list), result = try commit(broker, p)
            XCTAssertEqual(result["state"], .string("applied"), action); XCTAssertEqual(try commit(broker, p), result); XCTAssertEqual(base.writeCount, 1)
            let rollback = try inverse(broker, result), undone = try commit(broker, rollback, rollback: true)
            XCTAssertEqual(undone["state"], .string("applied"), action); XCTAssertEqual(base.writeCount, 2)
            XCTAssertEqual(try commit(broker, rollback, rollback: true), undone); XCTAssertEqual(base.writeCount, 2)
            XCTAssertThrowsError(try inverse(broker, result)); XCTAssertEqual(try state.rows("SELECT nonce FROM executions").count, 2)
            try state.verifyAudit()
            if action == "delete" { XCTAssertNotEqual(undone["reminder"]["id"], p["envelope"]["before"]["id"]) }
        }
    }
    func testEveryActionPreEntryFailureIsDurableAndDoesNotRefundQuota() throws {
        for action in ["create", "modify", "complete", "reopen", "delete"] {
            let (state, _, probe, broker) = try fixture(completed: action == "reopen"), (list, targets) = try ids(broker)
            let p = try preview(broker, action: action, id: targets[0], list: list); probe.mode = "before"
            let result = try commit(broker, p)
            XCTAssertEqual(result["state"], .string("not_applied")); XCTAssertEqual(probe.entries, 0); XCTAssertTrue(try state.isProvenNotApplied(result["nonce"].string!))
            XCTAssertEqual(try commit(broker, p), result); XCTAssertEqual(try state.rows("SELECT nonce FROM quota").count, action == "create" ? 0 : 1)
            probe.mode = "success"; let next = try preview(broker, action: action, id: targets[0], list: list)
            XCTAssertEqual(try commit(broker, next)["state"], .string("applied")); try state.verifyAudit()
        }
    }
    func testEnteredThrowRefreshFailureUntypedAndTypedLaterReadStayUnknown() throws {
        for mode in ["entered", "after", "untyped", "typed_readback"] {
            let (state, _, probe, broker) = try fixture(), (list, targets) = try ids(broker), p = try preview(broker, action: "modify", id: targets[0], list: list)
            probe.mode = mode; let result = try commit(broker, p)
            XCTAssertEqual(result["state"], .string("unknown")); XCTAssertFalse(try state.isProvenNotApplied(result["nonce"].string!))
            XCTAssertFalse(try result.text().contains("Private")); XCTAssertEqual(try commit(broker, p), result)
            if mode == "after" { XCTAssertEqual(result["diagnostic"]["stage"], .string("provider_refresh")) }
            probe.mode = "success"; probe.returned = false
            XCTAssertThrowsError(try preview(broker, action: "modify", id: targets[0], list: list))
            XCTAssertNotEqual(try preview(broker, action: "modify", id: targets[1], list: list), .null)
        }
    }
    func testUnknownCreateHoldsItsListButNotIndependentList() throws {
        let (_, _, probe, broker) = try fixture(), (list, targets) = try ids(broker), p = try preview(broker, action: "create", id: targets[0], list: list)
        probe.mode = "entered"; XCTAssertEqual(try commit(broker, p)["state"], .string("unknown")); probe.mode = "success"
        XCTAssertThrowsError(try preview(broker, action: "modify", id: targets[0], list: list))
        let otherList = try call(broker, "list_reminder_lists")["lists"].array!.first { $0["title"] == .string("Second") }!["id"].string!
        XCTAssertNotEqual(try preview(broker, action: "create", id: targets[0], list: otherList), .null)
    }
    func testAssessmentIsJournalOnlyIdempotentAndNeverRecoveryProof() throws {
        let (state, base, probe, broker) = try fixture(), (list, targets) = try ids(broker), p = try preview(broker, action: "modify", id: targets[0], list: list)
        probe.mode = "entered"; let unknown = try commit(broker, p), count = base.writeCount
        let assessment = try call(broker, "preflight_reminder_reconciliation", .object(["change_id": unknown["nonce"], "outcome": .string("not_applied"), "evidence": .string("Explicit synthetic user assessment")]))["preview"]
        let receipt = try call(broker, "commit_reminder_reconciliation", .object(["preview": assessment]))
        XCTAssertEqual(receipt["verification"], .string("not_performed")); XCTAssertEqual(try call(broker, "commit_reminder_reconciliation", .object(["preview": assessment])), receipt); XCTAssertEqual(base.writeCount, count)
        let source = try state.execution(unknown["nonce"].string!)!
        XCTAssertEqual(source.result["previous_result"], unknown); XCTAssertEqual(source.payload, p["envelope"]); XCTAssertFalse(try state.isProvenNotApplied(source.nonce)); XCTAssertThrowsError(try inverse(broker, unknown))
        XCTAssertFalse(try state.rows("SELECT receipt FROM assessments")[0][0].contains("Explicit synthetic")); try state.verifyAudit()
    }
    func testFailedUnenteredInverseDoesNotConsumeSource() throws {
        let (_, _, probe, broker) = try fixture(), (list, targets) = try ids(broker), result = try commit(broker, preview(broker, action: "modify", id: targets[0], list: list)), p = try inverse(broker, result)
        probe.mode = "before"; XCTAssertEqual(try commit(broker, p, rollback: true)["state"], .string("not_applied")); probe.mode = "success"
        XCTAssertEqual(try commit(broker, inverse(broker, result), rollback: true)["state"], .string("applied"))
    }
    func testRichLocalAlarmIsPreservedAcrossTitleInverse() throws {
        let (_, base, _, broker) = try fixture(); var details = base.records[0].details.object!; details["alarms"] = .array([.object(["type": .int(1), "relative_offset": .string("-60"), "sound_name": .string("local")])]); base.records[0].details = .object(details)
        let (list, _) = try ids(broker), id = try stateID(broker, native: base.records[0].nativeID)
        let changed = try commit(broker, preview(broker, action: "modify", id: id, list: list)); XCTAssertEqual(changed["state"], .string("applied"))
        XCTAssertEqual(try commit(broker, inverse(broker, changed), rollback: true)["state"], .string("applied")); XCTAssertEqual(base.records.first { $0.nativeID == "first" }!.details["alarms"], details["alarms"]!)
    }
    func stateID(_ broker: ReminderBroker, native: String) throws -> String { try broker.state.identity(kind: "reminder", nativeID: native, listID: "list-a") }
    func testDirectSaveNewIdentityProvenanceSupportsInverse() throws {
        let (_, _, probe, broker) = try fixture(), (list, targets) = try ids(broker); probe.mode = "new_id"
        let changed = try commit(broker, preview(broker, action: "modify", id: targets[0], list: list)); XCTAssertEqual(changed["state"], .string("applied")); probe.mode = "success"
        XCTAssertEqual(try commit(broker, inverse(broker, changed), rollback: true)["state"], .string("applied"))
    }
    func testUnsafeExternalAlarmRecurrenceAndUnsupportedComponentsFailBeforeIntent() throws {
        for detail in [JSON.object(["alarms": .array([.object(["type": .int(2), "email_address": .string("invalid")])])]), .object(["has_recurrence_rules": .bool(true), "recurrence_rules": .array([])])] {
            let (state, base, _, broker) = try fixture(); var raw = base.records[0].details.object!; raw.merge(detail.object!) { _, new in new }; base.records[0].details = .object(raw)
            _ = try ids(broker); let id = try stateID(broker, native: "first"), list = try state.identity(kind: "list", nativeID: "list-a")
            for action in ["modify", "complete", "delete"] { XCTAssertThrowsError(try preview(broker, action: action, id: id, list: list)) }
            XCTAssertEqual(base.writeCount, 0); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
        }
    }
    func testUnchangedAlertsCanonicalizeAwayAndNoopRejects() throws {
        let (_, _, _, broker) = try fixture(), (list, targets) = try ids(broker)
        let value = try call(broker, "preflight_reminder_change", .object(["action": .string("modify"), "scope": .string("this"), "reminder_id": .string(targets[0]), "fields": .object(["title": .string("New title"), "alerts": .array([])])]))["preview"]
        XCTAssertNil(value["envelope"]["after"]["fields"].object?["alerts"]); XCTAssertEqual(value["envelope"]["changed_fields"], .array([.string("title")])); XCTAssertEqual(try commit(broker, value)["state"], .string("applied"))
        XCTAssertThrowsError(try call(broker, "preflight_reminder_change", .object(["action": .string("modify"), "scope": .string("this"), "reminder_id": .string(targets[0]), "fields": .object(["alerts": .array([])])]))); _ = list
    }
    func testDatesAndStrictPriorityValidation() throws {
        func date(_ d: String, _ t: JSON = .null, _ z: JSON = .null) -> JSON { .object(["date": .string(d), "time": t, "time_zone": z]) }
        XCTAssertThrowsError(try ReminderDate(date("2027-02-29"))); XCTAssertThrowsError(try ReminderDate(date("2026-02-30")))
        XCTAssertThrowsError(try ReminderDate(date("2026-03-29", .string("01:30:00"), .string("Europe/London"))))
        XCTAssertThrowsError(try ReminderDate(date("2026-10-25", .string("01:30:00"), .string("Europe/London"))))
        let valid = try ReminderDate(date("2026-07-02", .string("12:30:00"), .string("Europe/London"))); XCTAssertEqual(valid.components().timeZone?.identifier, "Europe/London")
        XCTAssertNil(try ReminderDate(date("2028-02-29")).components().timeZone)
        XCTAssertEqual(try ReminderDate(date("2026-07-02", .string("12:30:00"), .string("UTC"))).timeZone, "GMT")
        XCTAssertThrowsError(try ReminderDate(date("2026-07-02", .string("12:30:00"), .string("GMT+0100"))))
        XCTAssertNil(try ReminderDate(date("2026-07-02", .string("12:30:00"))).components().timeZone)
        var f = try fields().json.object!; f["priority"] = .bool(true); XCTAssertThrowsError(try ReminderFields(.object(f)))
        XCTAssertThrowsError(try JSON.parse(Data("{\"priority\":1.1}".utf8)))
        let (_, _, _, broker) = try fixture(), (list, _) = try ids(broker)
        XCTAssertEqual(try call(broker, "query_reminders", .object(["list_id": .string(list), "include_undated": .bool(false)]))["reminders"], .array([]))
        XCTAssertNoThrow(try ReminderFields.merged(.object(["title": .string(String(repeating: "é", count: 1000))]), with: nil))
    }
    func testAuthenticatedSemanticTamperAndCrossDomainRejectBeforeIntent() throws {
        let (state, _, _, broker) = try fixture(), (list, targets) = try ids(broker), original = try preview(broker, action: "modify", id: targets[0], list: list)
        var value = original["envelope"].object!; value["completion_date_policy"] = .string("clear")
        let signed = try broker.sign(.object(value), domain: "reminders")
        XCTAssertThrowsError(try commit(broker, signed)); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
        XCTAssertThrowsError(try call(broker, "commit_reminder_delete", .object(["preview": original])))
        value["domain"] = .string("calendar"); XCTAssertThrowsError(try commit(broker, broker.sign(.object(value), domain: "reminders")))
        XCTAssertThrowsError(try call(broker, "commit_reminder_modify", .object(["preview": original, "approved": .bool(true)])))
    }
    func testDefaultQuotaPreservesFiftyAndFiftyOneBoundary() throws {
        let (state, base, _, broker) = try fixture()
        base.records = try (0...50).map { try record("quota-" + String($0)) }
        let (list, targets) = try ids(broker)
        for target in targets.prefix(50) {
            XCTAssertEqual(try commit(broker, preview(broker, action: "delete", id: target, list: list))["state"], .string("applied"))
        }
        XCTAssertEqual(targets.count, 51)
        let last = try preview(broker, action: "delete", id: XCTUnwrap(targets.dropFirst(50).first), list: list)
        XCTAssertThrowsError(try commit(broker, last)); XCTAssertEqual(base.writeCount, 50); XCTAssertEqual(try state.rows("SELECT nonce FROM quota").count, 50); XCTAssertEqual(try state.rows("SELECT nonce FROM executions").count, 50)
    }
    func testConcurrentExactReplayClaimsOneMutationAndOneQuota() throws {
        let (state, base, _, broker) = try fixture(), (list, targets) = try ids(broker), p = try preview(broker, action: "modify", id: targets[0], list: list)
        let request: JSON = .object(["op": .string("commit_reminder_modify"), "arguments": .object(["preview": p])])
        DispatchQueue.concurrentPerform(iterations: 8) { _ in _ = broker.handle(request) }
        XCTAssertEqual(base.writeCount, 1); XCTAssertEqual(try state.rows("SELECT nonce FROM quota").count, 1); XCTAssertEqual(try state.rows("SELECT count FROM observations WHERE bucket='replayed:modify'")[0][0], "7"); try state.verifyAudit()
    }
    func testUnresolvedInversePinsSourceAlongsideIndependentRoot() throws {
        let (state, _, probe, broker) = try fixture(), (list, targets) = try ids(broker), applied = try commit(broker, preview(broker, action: "modify", id: targets[0], list: list))
        let rollback = try inverse(broker, applied); probe.mode = "entered"
        XCTAssertEqual(try commit(broker, rollback, rollback: true)["state"], .string("unknown")); probe.mode = "success"
        let other = try call(broker, "list_reminder_lists")["lists"].array!.first { $0["title"] == .string("Second") }!["id"].string!, pending = try preview(broker, action: "create", id: targets[0], list: other)
        probe.mode = "entered"; XCTAssertEqual(try commit(broker, pending)["state"], .string("unknown"))
        try state.expire(now: Date().addingTimeInterval(366 * 86400))
        for nonce in [applied["nonce"].string!, rollback["envelope"]["nonce"].string!, pending["envelope"]["nonce"].string!] { XCTAssertTrue(try state.execution(nonce)!.detailsAvailable) }
        try state.verifyAudit()
    }

    func testUTCDateCanonicalizesInPreviewBeforeClaimAndReadback() throws {
        let (_, _, _, broker) = try fixture(), (list, _) = try ids(broker)
        let preview = try call(broker, "preflight_reminder_change", .object(["action": .string("create"), "scope": .string("this"), "list_id": .string(list), "fields": .object(["title": .string("UTC fixture"), "due": .object(["date": .string("2026-11-01"), "time": .string("12:00:00"), "time_zone": .string("UTC")])])]))["preview"]
        XCTAssertEqual(preview["envelope"]["after"]["fields"]["due"]["time_zone"], .string("GMT")); XCTAssertEqual(try commit(broker, preview)["state"], .string("applied"))
    }

}
