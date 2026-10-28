// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import Foundation
@testable import CalendarCore

/// Models an SDK that stores new completion assignments at whole-second precision.
private final class SecondsReminderProvider: ReminderBackend {
    let base: SyntheticReminderBackend
    var mode = "normal"
    var assigned: [Date] = []
    init(_ base: SyntheticReminderBackend) { self.base = base }
    func lists() throws -> [ReminderListRecord] { try base.lists() }
    func query(listID: String) throws -> [ReminderRecord] { try base.query(listID: listID) }
    func get(nativeID: String, listID: String) throws -> ReminderRecord { try base.get(nativeID: nativeID, listID: listID) }
    func apply(action: String, listID: String, existing: ReminderRecord?, fields: ReminderFields?, completed: Bool?, changedFields: [String], completionPolicy: String, completionDate: Date?, restoration: JSON?) throws -> ReminderWriteResult {
        try ProviderMutationAttempt.run { attempt in
            let result = try attempt.mutate {
                let written = try base.apply(action: action, listID: listID, existing: existing, fields: fields, completed: completed, changedFields: changedFields, completionPolicy: completionPolicy, completionDate: completionDate, restoration: restoration)
                guard var record = written.record else { return written }
                let chosen = completionPolicy == "set_on_commit" && mode == "legacy_fraction" ? base.completionClock() : written.completionDate
                if completionPolicy == "set_on_commit", let chosen {
                    assigned.append(chosen) // Observe the exact assignment before SDK normalization.
                    let storedSeconds = Double(Int64(chosen.timeIntervalSince1970)) + (mode == "wrong_second" ? 1 : 0)
                    let stored = Date(timeIntervalSince1970: storedSeconds)
                    record.completionDate = iso(stored)
                    var details = record.details.object!; details["completion_date_reference"] = .string(String(stored.timeIntervalSinceReferenceDate.bitPattern))
                    if mode == "unmasked" { details["url"] = .string("https://example.invalid/changed") }
                    record.details = .object(details)
                    base.records.removeAll { $0.nativeID == record.nativeID }; base.records.append(record)
                }
                return ReminderWriteResult(record: record, completionDate: chosen)
            }
            attempt.reading(.providerRefresh)
            if let record = result.record, let fields, let completed {
                try ReminderWriteWitness.verify(existing: existing, actual: record, fields: fields, completed: completed, changedFields: changedFields, completionDate: result.completionDate, restoration: restoration)
            }
            return result
        }
    }
}

final class ReminderCompletionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000.875)
    fileprivate func fixture(completed: Bool = false) throws -> (ReminderStateStore, SyntheticReminderBackend, SecondsReminderProvider, ReminderBroker, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-completion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let state = try ReminderStateStore(directory: directory, backendMode: "synthetic", credentialBinding: String(repeating: "a", count: 64))
        let fields = try ReminderFields(.object(["title": .string("Synthetic completion fixture"), "notes": .string(""), "priority": .int(0), "start": .null, "due": .null]))
        let old = completed ? Date(timeIntervalSinceReferenceDate: 800_000_000.1234567) : nil
        let record = ReminderRecord(nativeID: "completion-fixture", listNativeID: "synthetic-reminders", fields: fields, completed: completed, completionDate: old.map(iso), details: .object([
            "start_components": .null, "due_components": .null, "completion_date_reference": old.map { .string(String($0.timeIntervalSinceReferenceDate.bitPattern)) } ?? .null,
            "alarms": .array([]), "recurrence_rules": .array([]), "has_recurrence_rules": .bool(false), "url": .null, "location": .null, "item_time_zone": .null, "attendees": .array([])]))
        let base = SyntheticReminderBackend(reminders: [record]), capturedNow = now; base.completionClock = { capturedNow }
        let provider = SecondsReminderProvider(base), broker = ReminderBroker(state: state, backend: provider)
        let list = try call(broker, "list_reminder_lists")["lists"].array![0]["id"]
        let id = try call(broker, "query_reminders", .object(["list_id": list, "status": .string("all")]))["reminders"].array![0]["id"].string!
        return (state, base, provider, broker, id)
    }
    func call(_ broker: ReminderBroker, _ name: String, _ arguments: JSON = .object([:])) throws -> JSON {
        let response = broker.handle(.object(["op": .string(name), "arguments": arguments]))
        guard response["error"] == .null else { throw CoreError("fixture_failed", "Synthetic completion fixture failed") }; return response["result"]
    }
    func preview(_ broker: ReminderBroker, _ action: String, _ id: String, fields: JSON? = nil) throws -> JSON {
        var arguments: [String: JSON] = ["action": .string(action), "scope": .string("this"), "reminder_id": .string(id)]
        if let fields { arguments["fields"] = fields }
        return try call(broker, "preflight_reminder_change", .object(arguments))["preview"]
    }
    func commit(_ broker: ReminderBroker, _ preview: JSON) throws -> JSON {
        try call(broker, "commit_reminder_" + preview["envelope"]["action"].string!, .object(["preview": preview]))
    }
    func testNewCompletionChoosesWholeSecondBeforeSDKAssignment() throws {
        let (state, _, provider, broker, id) = try fixture(), signed = try preview(broker, "complete", id), result = try commit(broker, signed)
        XCTAssertEqual(provider.assigned, [Date(timeIntervalSince1970: 1_800_000_000)])
        XCTAssertNotEqual(provider.assigned.first, now)
        XCTAssertEqual(result["state"], .string("applied")); XCTAssertEqual(result["reminder"]["completion_date"], .string(iso(provider.assigned[0])))
        let raw = result["reminder"]["details"]["completion_date_reference"].string!
        XCTAssertEqual(raw, String(provider.assigned[0].timeIntervalSinceReferenceDate.bitPattern))
        XCTAssertEqual(try commit(broker, signed), result); XCTAssertEqual(provider.assigned.count, 1)
        XCTAssertEqual(try state.rows("SELECT nonce FROM quota").count, 1); try state.verifyAudit()
    }
    func testNewTimestampFloorsInsteadOfRoundingOrUsingLocalTime() {
        XCTAssertEqual(ReminderCompletionTime.onCommit(now: Date(timeIntervalSince1970: 10.999)), Date(timeIntervalSince1970: 10))
        XCTAssertEqual(ReminderCompletionTime.onCommit(now: Date(timeIntervalSince1970: -0.125)), Date(timeIntervalSince1970: -1))
        XCTAssertEqual(ReminderCompletionTime.onCommit(now: Date(timeIntervalSince1970: 12)), Date(timeIntervalSince1970: 12))
    }
    func testLegacyFractionalAssignmentStillFailsExactVerificationAfterSDKNormalization() throws {
        let (state, _, provider, broker, id) = try fixture(); provider.mode = "legacy_fraction"
        let result = try commit(broker, preview(broker, "complete", id))
        XCTAssertEqual(provider.assigned, [now]); XCTAssertEqual(result["state"], .string("unknown"))
        XCTAssertEqual(result["diagnostic"]["stage"], .string("provider_refresh")); XCTAssertEqual(result["diagnostic"]["code"], .string("verification_failed"))
        XCTAssertFalse(try state.isProvenNotApplied(result["nonce"].string!)); XCTAssertEqual(try state.rows("SELECT nonce FROM quota").count, 1)
    }
    func testWrongReturnedSecondAndUnmaskedMetadataStillRemainUnknown() throws {
        for mode in ["wrong_second", "unmasked"] {
            let (state, base, provider, broker, id) = try fixture(); provider.mode = mode
            let signed = try preview(broker, "complete", id), result = try commit(broker, signed)
            XCTAssertEqual(provider.assigned, [Date(timeIntervalSince1970: 1_800_000_000)])
            XCTAssertEqual(result["state"], .string("unknown"), mode); XCTAssertEqual(result["diagnostic"]["stage"], .string("provider_refresh"))
            XCTAssertEqual(try commit(broker, signed), result); XCTAssertEqual(base.writeCount, 1)
            XCTAssertFalse(try state.isProvenNotApplied(result["nonce"].string!)); XCTAssertThrowsError(try preview(broker, "reopen", id)); try state.verifyAudit()
        }
    }
    func testHistoricalSubsecondPreserveAndReopenInverseRemainExact() throws {
        for action in ["modify", "reopen"] {
            let (_, base, provider, broker, id) = try fixture(completed: true), original = try base.records[0].exactCompletionDate()!
            let signed = try preview(broker, action, id, fields: action == "modify" ? .object(["title": .string("Changed fixture")]) : nil)
            let result = try commit(broker, signed); XCTAssertEqual(result["state"], .string("applied"))
            if action == "modify" { XCTAssertEqual(try base.records[0].exactCompletionDate(), original) }
            else { XCTAssertNil(try base.records[0].exactCompletionDate()) }
            let inverse = try call(broker, "preflight_reminder_rollback", .object(["change_id": result["nonce"]]))["steps"].array![0]["preview"]
            XCTAssertEqual(inverse["envelope"]["rollback"]["restoration_details"]["completion_date_reference"], .string(String(original.timeIntervalSinceReferenceDate.bitPattern)))
            let restored = try call(broker, "commit_reminder_rollback", .object(["preview": inverse]))
            XCTAssertEqual(restored["state"], .string("applied")); XCTAssertEqual(try base.records[0].exactCompletionDate(), original)
            XCTAssertTrue(provider.assigned.isEmpty)
        }
    }
}
