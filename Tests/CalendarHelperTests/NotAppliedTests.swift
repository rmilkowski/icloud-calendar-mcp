// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import Foundation
import CryptoKit
@testable import CalendarCore

private final class MutationEntryProbe: CalendarBackend {
    let base: SyntheticBackend
    var mode = "success"
    var calls = 0
    var returned = false
    init(_ base: SyntheticBackend) { self.base = base }
    func calendars() throws -> [CalendarRecord] { try base.calendars() }
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] { try base.query(start: start, end: end, calendarIDs: calendarIDs) }
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord {
        if returned && mode == "typed_readback" { return try ProviderMutationAttempt.run { _ in throw CoreError("stale_event", "Synthetic later read failure") } }
        return try base.get(nativeID: nativeID, calendarID: calendarID, occurrence: occurrence, knownStart: knownStart)
    }
    func firstSeriesOccurrence(for selected: EventRecord) throws -> EventRecord {
        if returned && mode == "typed_readback" { return try ProviderMutationAttempt.run { _ in throw CoreError("stale_event", "Synthetic later master read failure") } }
        return try base.firstSeriesOccurrence(for: selected)
    }
    func allDayProjectionTimeZone() throws -> String { try base.allDayProjectionTimeZone() }
    private func write<T>(_ operation: () throws -> T) throws -> T {
        if mode == "untyped" { throw CoreError("stale_event", "Synthetic uninstrumented failure") }
        let result = try ProviderMutationAttempt.run { attempt in
            if mode == "before" { throw CoreError("stale_event", "Private fixture text must never escape") }
            if mode == "raw_before" { throw NSError(domain: "PrivateFixtureDomain", code: 9876, userInfo: [NSLocalizedDescriptionKey: "Private fixture credential and event text"]) }
            let value = try attempt.mutate {
                calls += 1
                if mode == "entered" { throw NSError(domain: "PrivateFixtureDomain", code: 9876, userInfo: [NSLocalizedDescriptionKey: "Private fixture credential and event text"]) }
                return try operation()
            }
            if mode == "after" { attempt.reading(.providerPrefixRead); throw CoreError("event_missing", "Private fixture prefix text") }
            return value
        }
        returned = true
        return result
    }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? { try write { try base.apply(action: action, calendarID: calendarID, existing: existing, fields: fields) } }
    func applyRestoringAlarms(calendarID: String, existing: EventRecord, fields: EventFields, alarms: JSON) throws -> EventRecord? { try write { try base.applyRestoringAlarms(calendarID: calendarID, existing: existing, fields: fields, alarms: alarms) } }
    func restore(calendarID: String, fields: EventFields, details: JSON, availability: String) throws -> EventRecord { try write { try base.restore(calendarID: calendarID, fields: fields, details: details, availability: availability) } }
    func applySeriesFields(anchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?) throws -> EventRecord { try write { try base.applySeriesFields(anchor: anchor, fields: fields, changedFields: changedFields, restoredAlarms: restoredAlarms) } }
    func applyFutureFields(selected: EventRecord, originalAnchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?, boundaryNow: () -> Date) throws -> FutureWriteResult { try write { try base.applyFutureFields(selected: selected, originalAnchor: originalAnchor, fields: fields, changedFields: changedFields, restoredAlarms: restoredAlarms, boundaryNow: boundaryNow) } }
    func removeFuture(selected: EventRecord, originalAnchor: EventRecord, boundaryNow: () -> Date) throws -> FutureRemovalResult { try write { try base.removeFuture(selected: selected, originalAnchor: originalAnchor, boundaryNow: boundaryNow) } }
    func restoreFutureTail(calendarID: String, originalSelected: EventRecord, expectedPrefix: EventRecord?, fields: EventFields, details: JSON, availability: String) throws -> EventRecord { try write { try base.restoreFutureTail(calendarID: calendarID, originalSelected: originalSelected, expectedPrefix: expectedPrefix, fields: fields, details: details, availability: availability) } }
    func applyAllDay(calendarID: String, existing: EventRecord?, fields: EventFields, interval: AllDayInterval, restoredAlarms: JSON?) throws -> EventRecord { try write { try base.applyAllDay(calendarID: calendarID, existing: existing, fields: fields, interval: interval, restoredAlarms: restoredAlarms) } }
}

final class NotAppliedTests: XCTestCase {
    private var directories: [URL] = []
    private let boundary = "2026-11-01T10:00:00.000Z"
    private let clock = try! parseDate("2026-10-25T12:00:00.000Z")
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at: directory) }; super.tearDown() }
    private func fixture() throws -> (StateStore, MutationEntryProbe, Broker) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-nonentry-" + UUID().uuidString); directories.append(directory)
        let state = try StateStore(directory: directory); try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "d", count: 64))
        let rule = try EventRecurrence(json: .object(["frequency": .string("weekly")]))
        let records = try ["2026-10-04T09:00:00.000Z", boundary, "2026-11-08T10:00:00.000Z"].map { date in
            EventRecord(nativeID: "synthetic-pattern", calendarNativeID: "synthetic-calendar", occurrence: date,
                        fields: EventFields(title: "Pattern fixture", start: date, end: iso(try parseDate(date).addingTimeInterval(3600)), timeZone: "Europe/London", allDay: false), recurring: true,
                        details: .object(["alarms": .array([]), "recurrence_rules": .array([rule.rawRule])]))
        }
        let ordinary = EventRecord(nativeID: "synthetic-item", calendarNativeID: "synthetic-calendar", fields: EventFields(title: "Item fixture", start: boundary, end: "2026-11-01T11:00:00.000Z", timeZone: "Europe/London", allDay: false), details: .object(["alarms": .array([])]))
        let independent = EventRecord(nativeID: "synthetic-independent", calendarNativeID: "synthetic-calendar", fields: EventFields(title: "Independent fixture", start: "2026-11-02T10:00:00.000Z", end: "2026-11-02T11:00:00.000Z", timeZone: "Europe/London", allDay: false), details: .object(["alarms": .array([])]))
        let allDay = EventRecord(nativeID: "synthetic-civil", calendarNativeID: "synthetic-calendar", fields: EventFields(title: "Civil fixture", start: "2026-11-03T00:00:00.000Z", end: "2026-11-03T23:59:59.000Z", timeZone: nil, allDay: true), details: .object(["alarms": .array([])]))
        let probe = MutationEntryProbe(SyntheticBackend(events: records + [ordinary, independent, allDay]))
        return (state, probe, Broker(state: state, backend: probe, now: { self.clock }))
    }
    private func call(_ broker: Broker, _ op: String, _ args: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(op), "arguments": .object(args)])) }
    private func preview(_ broker: Broker, _ arguments: [String: JSON]) throws -> JSON { try XCTUnwrap(call(broker, "preflight_change", arguments)["result"]["preview"].object.map(JSON.object)) }
    private struct Scenario { let tool: String; let action: String; let draft: () throws -> JSON }
    private func scenario(_ family: String, _ broker: Broker) throws -> Scenario {
        let events = try XCTUnwrap(call(broker, "query_events", ["start": .string("2026-10-01T00:00:00Z"), "end": .string("2026-12-01T00:00:00Z")])["result"]["events"].array)
        let ordinary = try XCTUnwrap(events.first { $0["fields"]["title"] == .string("Item fixture") })["id"]
        let recurring = try XCTUnwrap(events.first { $0["recurring"] == .bool(true) && $0["occurrence"] == .string(boundary) })["id"]
        let civil = try XCTUnwrap(events.first { $0["fields"]["all_day"] == .bool(true) })["id"]
        let calendar = try XCTUnwrap(call(broker, "list_calendars")["result"]["calendars"].array?.first?["id"])
        let sourceFamily: String
        switch family {
        case "alarms_inverse": sourceFamily = "modify"
        case "restore": sourceFamily = "delete"
        case "series_inverse": sourceFamily = "series"
        case "future_inverse": sourceFamily = "future"
        case "future_restore": sourceFamily = "termination"
        case "all_day_inverse": sourceFamily = "all_day_modify"
        default: sourceFamily = family
        }
        var arguments: [String: JSON] = ["scope": .string("this"), "action": .string("modify"), "event_id": ordinary, "fields": .object(["title": .string("Changed fixture")])]
        var tool = "commit_modify", action = "modify"
        switch sourceFamily {
        case "create", "series_create", "all_day_create":
            action = "create"; tool = "commit_create"
            let fields: JSON = sourceFamily == "all_day_create" ? .object(["title": .string("Created civil"), "all_day_dates": .object(["start_date": .string("2026-11-05"), "end_date_exclusive": .string("2026-11-06")])]) : .object(["title": .string("Created fixture"), "start": .string(boundary), "end": .string("2026-11-01T11:00:00Z"), "recurrence": sourceFamily == "series_create" ? .object(["frequency": .string("weekly")]) : .null])
            var value = fields.object!; if value["recurrence"] == .null { value.removeValue(forKey: "recurrence") }
            arguments = ["action": .string("create"), "scope": .string(sourceFamily == "series_create" ? "series" : "this"), "calendar_id": calendar, "fields": .object(value)]
        case "delete": action = "delete"; tool = "commit_delete"; arguments.removeValue(forKey: "fields"); arguments["action"] = .string("delete")
        case "series", "future":
            tool = sourceFamily == "series" ? "commit_series_modify" : "commit_future_modify"
            arguments["scope"] = .string(sourceFamily); arguments["event_id"] = recurring
        case "termination":
            action = "delete"; tool = "commit_future_delete"
            arguments = ["action": .string("delete"), "scope": .string("future"), "event_id": recurring, "cutoff": .object(["at": .string(boundary)])]
        case "all_day_modify":
            arguments["event_id"] = civil; arguments["fields"] = .object(["all_day_dates": .object(["start_date": .string("2026-11-04"), "end_date_exclusive": .string("2026-11-05")])])
        default: break
        }
        if sourceFamily == family { return Scenario(tool: tool, action: action, draft: { try self.preview(broker, arguments) }) }
        let source = call(broker, tool, ["preview": try preview(broker, arguments)])
        XCTAssertEqual(source["result"]["state"], .string("applied"), family)
        let nonce = source["result"]["nonce"]
        let draft = { () throws -> JSON in
            let result = self.call(broker, "preflight_rollback", ["change_ids": .array([nonce])])
            return try XCTUnwrap(result["result"]["steps"].array?.first?["preview"].object.map(JSON.object))
        }
        let first = try draft()
        let route = family == "series_inverse" ? "commit_series_rollback" : (family == "future_inverse" ? "commit_future_rollback" : (family == "future_restore" ? "commit_future_restore" : "commit_rollback"))
        return Scenario(tool: route, action: first["envelope"]["action"].string!, draft: draft)
    }
    private func assertPreEntry(_ family: String) throws {
        let (state, probe, broker) = try fixture(), step = try scenario(family, broker), original = try step.draft()
        let priorRows = try state.rows("SELECT count(*) FROM executions")[0][0], priorCalls = probe.calls
        let priorCharges = Int(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0])!
        probe.mode = "before"; probe.returned = false
        let result = call(broker, step.tool, ["preview": original])
        XCTAssertEqual(result["result"]["state"], .string("not_applied"), family)
        XCTAssertEqual(result["result"]["execution_evidence"], StateStore.notEnteredEvidence)
        XCTAssertEqual(probe.calls, priorCalls); XCTAssertFalse(try state.hasUnresolved())
        XCTAssertEqual(call(broker, step.tool, ["preview": original]), result); XCTAssertEqual(probe.calls, priorCalls)
        XCTAssertEqual(Int(try state.rows("SELECT count(*) FROM executions")[0][0]), Int(priorRows)! + 1)
        XCTAssertEqual(Int(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0]), priorCharges + (step.action == "create" ? 0 : 1))
        XCTAssertEqual(try state.auditRecords().filter { $0["event"] == .string("write_not_applied") }.count, 1)
        probe.mode = "success"; probe.returned = false
        let retry = call(broker, step.tool, ["preview": try step.draft()])
        XCTAssertEqual(retry["result"]["state"], .string("applied"), family)
        XCTAssertEqual(probe.calls, priorCalls + 1)
        let events = call(broker, "query_events", ["start": .string("2026-11-02T00:00:00Z"), "end": .string("2026-11-03T00:00:00Z")])["result"]["events"].array!
        let independent = try XCTUnwrap(events.first { $0["fields"]["title"] == .string("Independent fixture") })["id"]
        let unrelated = try preview(broker, ["action": .string("modify"), "scope": .string("this"), "event_id": independent, "fields": .object(["notes": .string("Independent edit")])])
        XCTAssertEqual(call(broker, "commit_modify", ["preview": unrelated])["result"]["state"], .string("applied"), family)
        try state.verifyAudit()
    }

    private func assertUnknown(_ family: String, mode: String) throws {
        let (state, probe, broker) = try fixture(), step = try scenario(family, broker), review = try step.draft(), before = probe.calls
        probe.mode = mode; probe.returned = false
        let result = call(broker, step.tool, ["preview": review])
        XCTAssertEqual(result["result"]["state"], .string("unknown"), family + ":" + mode)
        XCTAssertTrue(try state.hasUnresolved()); XCTAssertEqual(call(broker, step.tool, ["preview": review]), result)
        XCTAssertEqual(probe.calls, before + (mode == "untyped" ? 0 : 1))
        XCTAssertTrue(try state.auditRecords().filter { $0["event"] == .string("write_not_applied") }.isEmpty)
        if let source = review["envelope"]["rollback"]["source_change_ids"].array?.first {
            XCTAssertTrue(try state.recoveryHeldNonces().contains(source.string!))
            XCTAssertNotEqual(call(broker, "preflight_rollback", ["change_ids": .array([source])])["error"], .null)
        }
        let wire = try result.text(); XCTAssertFalse(wire.contains("PrivateFixture")); XCTAssertFalse(wire.contains("credential and event text"))
    }

    func testPreEntryCreate() throws { try assertPreEntry("create") }
    func testPreEntrySeriesCreate() throws { try assertPreEntry("series_create") }
    func testPreEntryModify() throws { try assertPreEntry("modify") }
    func testPreEntryDelete() throws { try assertPreEntry("delete") }
    func testPreEntryAlarmsInverse() throws { try assertPreEntry("alarms_inverse") }
    func testPreEntryRestore() throws { try assertPreEntry("restore") }
    func testPreEntrySeries() throws { try assertPreEntry("series") }
    func testPreEntrySeriesInverse() throws { try assertPreEntry("series_inverse") }
    func testPreEntryFuture() throws { try assertPreEntry("future") }
    func testPreEntryFutureInverse() throws { try assertPreEntry("future_inverse") }
    func testPreEntryTermination() throws { try assertPreEntry("termination") }
    func testPreEntryFutureRestore() throws { try assertPreEntry("future_restore") }
    func testPreEntryAllDayCreate() throws { try assertPreEntry("all_day_create") }
    func testPreEntryAllDayModify() throws { try assertPreEntry("all_day_modify") }
    func testPreEntryAllDayInverse() throws { try assertPreEntry("all_day_inverse") }
    func testUnknownCreateEntered() throws { try assertUnknown("create", mode: "entered") }
    func testUnknownSeriesCreateEntered() throws { try assertUnknown("series_create", mode: "entered") }
    func testUnknownModifyEntered() throws { try assertUnknown("modify", mode: "entered") }
    func testUnknownDeleteEntered() throws { try assertUnknown("delete", mode: "entered") }
    func testUnknownAlarmsInverseEntered() throws { try assertUnknown("alarms_inverse", mode: "entered") }
    func testUnknownRestoreEntered() throws { try assertUnknown("restore", mode: "entered") }
    func testUnknownSeriesEntered() throws { try assertUnknown("series", mode: "entered") }
    func testUnknownSeriesInverseEntered() throws { try assertUnknown("series_inverse", mode: "entered") }
    func testUnknownFutureEntered() throws { try assertUnknown("future", mode: "entered") }
    func testUnknownFutureInverseEntered() throws { try assertUnknown("future_inverse", mode: "entered") }
    func testUnknownTerminationEntered() throws { try assertUnknown("termination", mode: "entered") }
    func testUnknownFutureRestoreEntered() throws { try assertUnknown("future_restore", mode: "entered") }
    func testUnknownAllDayCreateEntered() throws { try assertUnknown("all_day_create", mode: "entered") }
    func testUnknownAllDayModifyEntered() throws { try assertUnknown("all_day_modify", mode: "entered") }
    func testUnknownAllDayInverseEntered() throws { try assertUnknown("all_day_inverse", mode: "entered") }
    func testUnknownCreateUntyped() throws { try assertUnknown("create", mode: "untyped") }
    func testUnknownSeriesCreateUntyped() throws { try assertUnknown("series_create", mode: "untyped") }
    func testUnknownModifyUntyped() throws { try assertUnknown("modify", mode: "untyped") }
    func testUnknownDeleteUntyped() throws { try assertUnknown("delete", mode: "untyped") }
    func testUnknownAlarmsInverseUntyped() throws { try assertUnknown("alarms_inverse", mode: "untyped") }
    func testUnknownRestoreUntyped() throws { try assertUnknown("restore", mode: "untyped") }
    func testUnknownSeriesUntyped() throws { try assertUnknown("series", mode: "untyped") }
    func testUnknownSeriesInverseUntyped() throws { try assertUnknown("series_inverse", mode: "untyped") }
    func testUnknownFutureUntyped() throws { try assertUnknown("future", mode: "untyped") }
    func testUnknownFutureInverseUntyped() throws { try assertUnknown("future_inverse", mode: "untyped") }
    func testUnknownTerminationUntyped() throws { try assertUnknown("termination", mode: "untyped") }
    func testUnknownFutureRestoreUntyped() throws { try assertUnknown("future_restore", mode: "untyped") }
    func testUnknownAllDayCreateUntyped() throws { try assertUnknown("all_day_create", mode: "untyped") }
    func testUnknownAllDayModifyUntyped() throws { try assertUnknown("all_day_modify", mode: "untyped") }
    func testUnknownAllDayInverseUntyped() throws { try assertUnknown("all_day_inverse", mode: "untyped") }
    func testUnknownCreateTypedReadback() throws { try assertUnknown("create", mode: "typed_readback") }
    func testUnknownSeriesCreateTypedReadback() throws { try assertUnknown("series_create", mode: "typed_readback") }
    func testUnknownModifyTypedReadback() throws { try assertUnknown("modify", mode: "typed_readback") }
    func testUnknownDeleteTypedReadback() throws { try assertUnknown("delete", mode: "typed_readback") }
    func testUnknownAlarmsInverseTypedReadback() throws { try assertUnknown("alarms_inverse", mode: "typed_readback") }
    func testUnknownRestoreTypedReadback() throws { try assertUnknown("restore", mode: "typed_readback") }
    func testUnknownSeriesTypedReadback() throws { try assertUnknown("series", mode: "typed_readback") }
    func testUnknownSeriesInverseTypedReadback() throws { try assertUnknown("series_inverse", mode: "typed_readback") }
    func testUnknownFutureTypedReadback() throws { try assertUnknown("future", mode: "typed_readback") }
    func testUnknownFutureInverseTypedReadback() throws { try assertUnknown("future_inverse", mode: "typed_readback") }
    func testUnknownTerminationTypedReadback() throws { try assertUnknown("termination", mode: "typed_readback") }
    func testUnknownFutureRestoreTypedReadback() throws { try assertUnknown("future_restore", mode: "typed_readback") }
    func testUnknownAllDayCreateTypedReadback() throws { try assertUnknown("all_day_create", mode: "typed_readback") }
    func testUnknownAllDayModifyTypedReadback() throws { try assertUnknown("all_day_modify", mode: "typed_readback") }
    func testUnknownAllDayInverseTypedReadback() throws { try assertUnknown("all_day_inverse", mode: "typed_readback") }
    func testUnknownCreateAfter() throws { try assertUnknown("create", mode: "after") }
    func testUnknownSeriesCreateAfter() throws { try assertUnknown("series_create", mode: "after") }
    func testUnknownModifyAfter() throws { try assertUnknown("modify", mode: "after") }
    func testUnknownDeleteAfter() throws { try assertUnknown("delete", mode: "after") }
    func testUnknownAlarmsInverseAfter() throws { try assertUnknown("alarms_inverse", mode: "after") }
    func testUnknownRestoreAfter() throws { try assertUnknown("restore", mode: "after") }
    func testUnknownSeriesAfter() throws { try assertUnknown("series", mode: "after") }
    func testUnknownSeriesInverseAfter() throws { try assertUnknown("series_inverse", mode: "after") }
    func testUnknownFutureAfter() throws { try assertUnknown("future", mode: "after") }
    func testUnknownFutureInverseAfter() throws { try assertUnknown("future_inverse", mode: "after") }
    func testUnknownTerminationAfter() throws { try assertUnknown("termination", mode: "after") }
    func testUnknownFutureRestoreAfter() throws { try assertUnknown("future_restore", mode: "after") }
    func testUnknownAllDayCreateAfter() throws { try assertUnknown("all_day_create", mode: "after") }
    func testUnknownAllDayModifyAfter() throws { try assertUnknown("all_day_modify", mode: "after") }
    func testUnknownAllDayInverseAfter() throws { try assertUnknown("all_day_inverse", mode: "after") }

    func testLeafAttemptCannotClaimNonEntryAfterEntryOrNormalReturnAndUnknownErrorsStayPrivate() throws {
        var calls = 0
        do { _ = try ProviderMutationAttempt.run { _ in 1 }; XCTFail("Normal return without mutation must fail") }
        catch let failure as ProviderMutationFailure { XCTAssertTrue(failure.provesNotEntered); XCTAssertEqual(failure.diagnostic.code, "internal_error") }
        do { _ = try ProviderMutationAttempt.run { attempt in try attempt.mutate { calls += 1 }; throw CoreError("private_arbitrary_code", "Private fixture") }; XCTFail("Must fail") }
        catch let failure as ProviderMutationFailure { XCTAssertFalse(failure.provesNotEntered); XCTAssertEqual(failure.diagnostic.code, "internal_error") }
        XCTAssertEqual(calls, 1)
        let (_, probe, broker) = try fixture(), step = try scenario("create", broker)
        probe.mode = "raw_before"
        let result = call(broker, step.tool, ["preview": try step.draft()])
        XCTAssertEqual(result["result"]["state"], .string("not_applied")); XCTAssertEqual(result["result"]["diagnostic"]["code"], .string("provider_error"))
        XCTAssertFalse(try result.text().contains("PrivateFixture"))
    }

    func testPersistenceFailureCannotReturnNonblockingOutcomeAndCrashRecoversUnknown() throws {
        for failure in ["state", "audit", "all_terminal"] {
            var directory: URL!
            do {
                let (state, probe, broker) = try fixture(); directory = state.directory
                let step = try scenario("modify", broker), review = try step.draft()
                if failure == "audit" {
                    try state.execute("CREATE TRIGGER fixture_no_terminal_audit BEFORE INSERT ON audit WHEN json_extract(NEW.body,'$.event')='write_not_applied' BEGIN SELECT RAISE(ABORT,'synthetic'); END")
                } else {
                    let condition = failure == "state" ? "NEW.state='not_applied'" : "NEW.state<>'intent_recorded'"
                    try state.execute("CREATE TRIGGER fixture_no_terminal BEFORE UPDATE OF state ON executions WHEN " + condition + " BEGIN SELECT RAISE(ABORT,'synthetic'); END")
                }
                probe.mode = "before"
                let result = call(broker, step.tool, ["preview": review])
                XCTAssertEqual(result["result"]["state"], .string("unknown")); XCTAssertTrue(try state.hasUnresolved())
                XCTAssertTrue(state.provenNotApplied.isEmpty); XCTAssertEqual(probe.calls, 0)
                XCTAssertTrue(try state.auditRecords().filter { $0["event"] == .string("write_not_applied") }.isEmpty)
                if failure == "all_terminal" {
                    XCTAssertEqual(try state.execution(review["envelope"]["nonce"].string!)?.state, "intent_recorded")
                    try state.execute("DROP TRIGGER fixture_no_terminal")
                }
            }
            let reopened = try StateStore(directory: directory)
            XCTAssertTrue(try reopened.hasUnresolved()); XCTAssertEqual(try reopened.rows("SELECT state FROM executions"), [["unknown"]])
            XCTAssertTrue(reopened.provenNotApplied.isEmpty)
        }
    }
    func testProofSurvivesExpiryRestartAndExactNonceReplayWithoutProviderAccess() throws {
        var directory: URL!, review: JSON!, proof: JSON!, before: [[String]]!
        do {
            let (state, probe, broker) = try fixture(); directory = state.directory
            let step = try scenario("modify", broker); review = try step.draft(); probe.mode = "before"
            proof = call(broker, step.tool, ["preview": review])["result"]
            before = try state.rows("SELECT nonce,payload,created FROM executions")
            try state.expireRecoveryDetails(now: clock.addingTimeInterval(10 * 86400))
            XCTAssertEqual(try state.rows("SELECT nonce,payload,created FROM executions"), before)
            XCTAssertTrue(try state.rows("SELECT nonce FROM execution_keys").isEmpty)
            XCTAssertTrue(try state.isProvenNotApplied(state.recoveryRows()[0])); try state.verifyAudit()
        }
        let state = try StateStore(directory: directory), probe = MutationEntryProbe(SyntheticBackend()), broker = Broker(state: state, backend: probe, now: { self.clock.addingTimeInterval(20 * 86400) })
        probe.mode = "untyped"
        let replay = call(broker, "commit_modify", ["preview": review])["result"]
        for key in ["nonce", "state", "action", "audit_sequence", "execution_evidence", "diagnostic"] { XCTAssertEqual(replay[key], proof[key], key) }
        XCTAssertEqual(probe.calls, 0); XCTAssertFalse(try state.hasUnresolved())
        XCTAssertEqual(try state.rows("SELECT nonce,payload,created FROM executions"), before)
        XCTAssertTrue(try state.isProvenNotApplied(state.recoveryRows()[0]))
    }
    private func rewriteAudit(_ state: StateStore, edit: (inout [String: JSON]) -> Void) throws {
        // Startup checks observe the completed tampered fixture, never an intermediate rewrite.
        try state.transaction {
            try state.execute("DROP TRIGGER audit_no_update")
            var previous = String(repeating: "0", count: 64)
            for row in try state.rows("SELECT sequence,body FROM audit ORDER BY sequence") {
                var body = try JSON.parse(Data(row[1].utf8)).object!
                if body["event"] == .string("write_not_applied") { edit(&body) }
                let text = try JSON.object(body).text(), hash = digest(Data((previous + text).utf8))
                try state.execute("UPDATE audit SET body=?,previous_hash=?,hash=? WHERE sequence=?", [text, previous, hash, row[0]])
                previous = hash
            }
        }
    }
    func testStartupRejectsMalformedOrUnmatchedNativeProofBeforeExpiry() throws {
        for mode in ["nonce", "action", "encoding", "evidence", "diagnostic", "sequence", "cipher", "cipher_nonce", "cipher_state", "cipher_extra", "audit_missing", "audit_context", "audit_diagnostic", "floor"] {
            var directory: URL!
            do {
                let (state, probe, broker) = try fixture(); directory = state.directory
                let step = try scenario("modify", broker); probe.mode = "before"
                let result = call(broker, step.tool, ["preview": try step.draft()])["result"], nonce = result["nonce"].string!
                var minimal = try JSON.parse(Data(state.rows("SELECT result FROM executions WHERE nonce=?", [nonce])[0][0].utf8)).object!
                switch mode {
                case "nonce": minimal["nonce"] = .string(UUID().uuidString)
                case "action": minimal["action"] = .string("delete")
                case "encoding": minimal["storage_version"] = .int(1); try state.execute("DROP TRIGGER execution_v2_result")
                case "evidence": minimal["execution_evidence"] = .object(["version": .int(1), "provider_mutation": .string("not_entered"), "caller": .bool(true)])
                case "diagnostic": minimal["diagnostic"] = .object(["version": .int(1), "stage": .string("provider_mutation"), "code": .string("stale_event")])
                case "sequence": minimal["audit_sequence"] = .int(999)
                case "cipher", "cipher_nonce", "cipher_state", "cipher_extra":
                    var replacement = result.object!
                    if mode == "cipher_nonce" { replacement["nonce"] = .string(UUID().uuidString) }
                    if mode == "cipher_state" { replacement["state"] = .string("applied") }
                    if mode == "cipher_extra" { replacement["caller_approved"] = .bool(true) }
                    if mode == "cipher" { replacement["diagnostic"] = .object(["version": .int(1), "stage": .string("provider_preflight"), "code": .string("internal_error")]) }
                    let key = Data(base64Encoded: try state.rows("SELECT key FROM execution_keys WHERE nonce=?", [nonce])[0][0])!
                    try state.execute("UPDATE execution_details SET result_cipher=? WHERE nonce=?", [try state.encrypted(.object(replacement), key: SymmetricKey(data: key), nonce: nonce, field: "result_cipher"), nonce])
                case "audit_missing": try state.execute("DROP TRIGGER audit_no_delete"); try state.execute("DELETE FROM audit WHERE json_extract(body,'$.event')='write_not_applied'")
                case "audit_context": try rewriteAudit(state) { $0["approval_source"] = .string("local_operator_attestation") }
                case "audit_diagnostic": try rewriteAudit(state) { body in var payload = body["payload"]!.object!; payload["diagnostic"] = .object(["version": .int(1), "stage": .string("provider_preflight"), "code": .string("internal_error")]); body["payload"] = .object(payload) }
                case "floor": try state.execute("UPDATE metadata SET value='6' WHERE key='recovery_storage_version'")
                default: break
                }
                try state.execute("UPDATE executions SET result=? WHERE nonce=?", [try JSON.object(minimal).text(), nonce])
            }
            XCTAssertThrowsError(try StateStore(directory: directory), mode)
        }
    }
    func testFailedInverseLocalUIProvenanceAndUserAttestationIsNeverNativeProof() throws {
        do {
            let (state, probe, broker) = try fixture(), step = try scenario("alarms_inverse", broker), review = try step.draft()
            probe.mode = "before"; let result = broker.commitReviewedRollback(review)
            XCTAssertEqual(result["result"]["state"], .string("not_applied"))
            let audit = try XCTUnwrap(state.auditRecords().last { $0["event"] == .string("write_not_applied") })
            XCTAssertEqual(audit["approval_source"], .string("local_native_ui")); XCTAssertEqual(audit["approval_evidence"], .string("native_control_activated"))
            XCTAssertTrue(try state.rows("SELECT source_nonce FROM recovery_links").isEmpty)
            probe.mode = "success"; XCTAssertEqual(broker.commitReviewedRollback(try step.draft())["result"]["state"], .string("applied")); try state.verifyAudit()
        }
        do {
            let (state, probe, broker) = try fixture(), step = try scenario("modify", broker)
            let applied = call(broker, step.tool, ["preview": try step.draft()])["result"]["nonce"]
            let second = try preview(broker, ["action": .string("modify"), "scope": .string("this"), "event_id": call(broker, "get_stored_change", ["change_id": applied])["result"]["change"]["event_id"], "fields": .object(["notes": .string("Later fixture")])])
            probe.mode = "untyped"; let unknown = call(broker, step.tool, ["preview": second])["result"]["nonce"].string!
            _ = try state.reconcile(nonce: unknown, outcome: "not_applied", evidence: "Synthetic user assessment")
            let row = try XCTUnwrap(state.recoveryRows().first { $0[0] == unknown }); XCTAssertFalse(try state.isProvenNotApplied(row))
            probe.mode = "success"
            XCTAssertNotEqual(call(broker, "preflight_rollback", ["change_ids": .array([applied])])["error"], .null)
        }
    }
    func testBulkRecoveryOmitsOnlyNativeNonExecutionWhileHistoryAndExplicitSelectionRemainVisible() throws {
        let (state, probe, broker) = try fixture(), step = try scenario("modify", broker)
        let first = call(broker, step.tool, ["preview": try step.draft()])["result"]["nonce"]
        let id = call(broker, "get_stored_change", ["change_id": first])["result"]["change"]["event_id"]
        var second: JSON = .null, failed: JSON = .null
        for index in 0..<26 {
            probe.mode = "before"
            failed = call(broker, "commit_modify", ["preview": try preview(broker, ["action": .string("modify"), "scope": .string("this"), "event_id": id, "fields": .object(["notes": .string("Not applied fixture \(index)")])])])["result"]["nonce"]
            if index == 12 {
                probe.mode = "success"
                second = call(broker, "commit_modify", ["preview": try preview(broker, ["action": .string("modify"), "scope": .string("this"), "event_id": id, "fields": .object(["notes": .string("Applied fixture")])])])["result"]["nonce"]
            }
        }
        probe.mode = "success"
        let plan = call(broker, "preflight_rollback", ["all": .bool(true)])
        XCTAssertEqual(plan["result"]["selected_change_ids"], .array([first, second]))
        XCTAssertNotEqual(call(broker, "preflight_rollback", ["change_ids": .array([failed])])["error"], .null)
        XCTAssertEqual(call(broker, "list_changes")["result"]["changes"].array?.count, 28)
        XCTAssertEqual(call(broker, "get_stored_change", ["change_id": failed])["result"]["change"]["state"], .string("not_applied"))
        try state.verifyAudit()
    }
    func testOrdinaryRecoveryCrossesOnlyProvenUnenteredBroaderIntents() throws {
        for family in ["series", "future", "termination", "all_day_modify"] {
            let (state, probe, broker) = try fixture(), ordinary = try scenario("modify", broker), broad = try scenario(family, broker)
            let source = call(broker, ordinary.tool, ["preview": try ordinary.draft()])["result"]["nonce"]
            probe.mode = "before"
            XCTAssertEqual(call(broker, broad.tool, ["preview": try broad.draft()])["result"]["state"], .string("not_applied"), family)
            probe.mode = "success"
            XCTAssertNotEqual(call(broker, "preflight_rollback", ["change_ids": .array([source])])["result"]["steps"], .null, family)
            try state.verifyAudit()
        }
    }
    func testFloorSixUpgradeAndFrozenWriterRefusalPreserveAllAuthoritativeRows() throws {
        let tables = ["executions", "execution_details", "execution_keys", "write_safety_claims", "audit", "legacy_audit_manifest", "legacy_audit_details", "identities", "recovery_links", "commit_observations", "commit_observation_clock", "reconciliation_claims"]
        var directory: URL!, snapshot: [String: [[String]]]!
        do {
            let (state, probe, broker) = try fixture(); directory = state.directory
            let create = try scenario("create", broker), step = try scenario("modify", broker)
            _ = call(broker, step.tool, ["preview": try step.draft()]); probe.mode = "untyped"
            let assessed = call(broker, "commit_create", ["preview": try create.draft()])["result"]["nonce"]
            let assessment = call(broker, "preflight_reconciliation", ["change_id": assessed, "outcome": .string("not_applied"), "evidence": .string("Synthetic compatibility assessment")])["result"]["preview"]
            XCTAssertEqual(call(broker, "commit_reconciliation", ["preview": assessment])["result"]["state"], .string("reconciled"))
            let unknown = call(broker, "commit_create", ["preview": try create.draft()])
            XCTAssertEqual(unknown["result"]["state"], .string("unknown"))
            // Only a synthetic compatibility fixture is assigned its historical floor.
            try state.execute("UPDATE metadata SET value='6' WHERE key='recovery_storage_version'")
            snapshot = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try state.rows("SELECT rowid,* FROM " + $0 + " ORDER BY rowid")) })
        }
        do {
            let state = try StateStore(directory: directory)
            XCTAssertEqual(try state.metadata("recovery_storage_version"), "7")
            for table in tables { XCTAssertEqual(try state.rows("SELECT rowid,* FROM " + table + " ORDER BY rowid"), snapshot[table], table) }
            XCTAssertTrue(try state.hasUnresolved()); try state.verifyAudit()
        }
        let helper = ProcessInfo.processInfo.environment["CALENDAR_MCP_FROZEN_FLOOR6_HELPER"] ?? "/private/tmp/calendar-journal-release-f3hcso6r/CalendarHelper"
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Frozen floor-six helper unavailable") }
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: helper); process.arguments = ["--migrate-recovery", "--state-dir", directory.path]; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1); XCTAssertEqual(try JSON.parse(bytes)["error"]["code"], .string("state_version"))
        let state = try StateStore(directory: directory)
        for table in tables { XCTAssertEqual(try state.rows("SELECT rowid,* FROM " + table + " ORDER BY rowid"), snapshot[table], table) }
    }
}
