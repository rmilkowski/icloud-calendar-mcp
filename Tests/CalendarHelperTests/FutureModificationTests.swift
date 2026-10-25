import XCTest
import Foundation
import CryptoKit
@testable import CalendarCore

private final class FutureProbeBackend: CalendarBackend {
    let base: SyntheticBackend
    var corrupt = ""
    var denyReads = false
    var providerReads = 0
    var getCalls = 0
    var changeOnGet: Int?
    var beforeApply: (() -> Void)?
    var afterAnchor: (() -> Void)?
    init(_ base: SyntheticBackend) { self.base = base }
    func calendars() throws -> [CalendarRecord] { providerReads += 1; if denyReads { throw CoreError("synthetic_reads_forbidden", "Unexpected provider read") }; return try base.calendars() }
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] { try base.query(start: start, end: end, calendarIDs: calendarIDs) }
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord { providerReads += 1; getCalls += 1; if denyReads { throw CoreError("synthetic_reads_forbidden", "Unexpected provider read") }; if getCalls == changeOnGet, let index = base.events.firstIndex(where: { $0.nativeID == nativeID && $0.occurrence == occurrence }) { base.events[index].fields.title = "External intervening masked change" }; return try base.get(nativeID: nativeID, calendarID: calendarID, occurrence: occurrence, knownStart: knownStart) }
    func firstSeriesOccurrence(for selected: EventRecord) throws -> EventRecord { providerReads += 1; if denyReads { throw CoreError("synthetic_reads_forbidden", "Unexpected provider read") }; let result = try base.firstSeriesOccurrence(for: selected); afterAnchor?(); return result }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? { try base.apply(action: action, calendarID: calendarID, existing: existing, fields: fields) }
    func applySeriesFields(anchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?) throws -> EventRecord { try base.applySeriesFields(anchor: anchor, fields: fields, changedFields: changedFields, restoredAlarms: restoredAlarms) }
    func applyFutureFields(selected: EventRecord, originalAnchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?, boundaryNow: () -> Date) throws -> FutureWriteResult {
        beforeApply?()
        let result = try base.applyFutureFields(selected: selected, originalAnchor: originalAnchor, fields: fields, changedFields: changedFields, restoredAlarms: restoredAlarms, boundaryNow: boundaryNow)
        var tail = result.boundary, past = result.pastAnchor
        switch corrupt {
        case "past_title": past?.fields.title = "Unexpected past title"
        case "past_time": past?.fields.end = "2026-10-04T12:00:00.000Z"
        case "past_alarm": var details = past!.details.object!; details["alarms"] = .array([try EventAlert(json: .object(["relative_minutes": .int(-30)])).rawAlarm]); past?.details = .object(details)
        case "past_rule": var details = past!.details.object!, rule = details["recurrence_rules"]!.array![0].object!; rule["interval"] = .int(9); details["recurrence_rules"] = .array([.object(rule)]); past?.details = .object(details)
        case "past_created": var details = past!.details.object!; details["created"] = .string("2026-10-25T08:00:00.000Z"); past?.details = .object(details)
        case "past_external": var details = past!.details.object!; details["external_id"] = .string("Unexpected identity"); past?.details = .object(details)
        case "missing_past": past = nil
        case "tail_rule": var details = tail.details.object!, rule = details["recurrence_rules"]!.array![0].object!; rule["interval"] = .int(9); details["recurrence_rules"] = .array([.object(rule)]); tail.details = .object(details)
        case "tail_time": tail.fields.start = "2026-11-01T12:00:00.000Z"
        default: break
        }
        return FutureWriteResult(boundary: tail, pastAnchor: past)
    }
}

final class FutureModificationTests: XCTestCase {
    private var directories: [URL] = []
    private let boundary = "2026-11-01T10:00:00.000Z"
    private let initialNow = try! parseDate("2026-10-25T09:00:00.000Z")
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at: directory) }; super.tearDown() }
    private func state() throws -> StateStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-future-fixture-" + UUID().uuidString); directories.append(directory)
        let state = try StateStore(directory: directory); try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "b", count: 64)); return state
    }
    private func fixture(rule supplied: JSON? = nil) throws -> SyntheticBackend {
        let rule = try supplied ?? EventRecurrence(json: .object(["frequency": .string("weekly"), "interval": .int(2)])).rawRule
        let starts = ["2026-10-04T10:00:00.000Z", boundary, "2026-11-15T10:00:00.000Z", "2026-11-29T10:00:00.000Z", "2026-11-22T10:00:00.000Z"]
        return SyntheticBackend(events: try starts.enumerated().map { index, start in
            EventRecord(nativeID: index == 4 ? "other-pattern" : "future-pattern", calendarNativeID: "synthetic-calendar", occurrence: start,
                        fields: EventFields(title: index == 3 ? "Detached" : "Original", start: start, end: iso(try parseDate(start).addingTimeInterval(3600)), timeZone: "Europe/London", allDay: false, notes: "Prior notes"), recurring: true, detached: index == 3,
                        details: .object(["recurrence_rules": .array([rule]), "alarms": .array([]), "url": .null, "structured_location": .null]))
        })
    }
    private func call(_ broker: Broker, _ operation: String, _ arguments: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(operation), "arguments": .object(arguments)])) }
    private func views(_ broker: Broker) -> [JSON] { call(broker, "query_events", ["start": .string("2026-10-01T00:00:00Z"), "end": .string("2026-12-10T00:00:00Z")])["result"]["events"].array! }
    private func draft(_ broker: Broker, _ id: JSON, fields: [String: JSON] = ["title": .string("Future title")], scope: String = "future") -> JSON { call(broker, "preflight_change", ["action": .string("modify"), "scope": .string(scope), "event_id": id, "fields": .object(fields)]) }
    private func commit(_ broker: Broker, _ preview: JSON, rollback: Bool = false) -> JSON { call(broker, rollback ? "commit_future_rollback" : "commit_future_modify", ["preview": preview]) }
    private func inverse(_ broker: Broker, _ nonce: JSON) -> JSON { call(broker, "preflight_rollback", ["change_ids": .array([nonce])]) }
    private func signed(_ envelope: [String: JSON], state: StateStore) throws -> JSON {
        let body = JSON.object(envelope), key = SymmetricKey(data: Data(base64Encoded: try state.metadata("signing_key")!)!)
        return .object(["envelope": body, "authentication_tag": .string(Data(HMAC<SHA256>.authenticationCode(for: try body.data(), using: key)).base64EncodedString())])
    }
    func testSelectedBoundaryInclusiveSplitPreservesEarlierFieldsAndOnlyRebindsSelected() throws {
        let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), events = views(broker)
        let selected = events.first { $0["occurrence"] == .string(boundary) }!, original = base.events
        let step = draft(broker, selected["id"])["result"], preview = step["preview"], envelope = preview["envelope"]
        XCTAssertEqual(step["commit_tool"], .string("commit_future_modify")); XCTAssertEqual(envelope["version"], .int(5))
        XCTAssertEqual(envelope["before"], selected); XCTAssertEqual(envelope["future"]["first_anchor"], events[0]); XCTAssertEqual(envelope["future"]["boundary"], selected["occurrence"])
        XCTAssertEqual(envelope["recovery"], Broker.futureRecovery); XCTAssertEqual(call(broker, "future_modification_capabilities")["result"], Broker.futureModificationCapabilities)
        for op in ["commit_modify", "commit_rollback", "commit_series_modify", "commit_series_rollback", "commit_future_rollback"] { XCTAssertNotEqual(call(broker, op, ["preview": preview])["error"], .null) }
        let result = commit(broker, preview)
        XCTAssertEqual(result["result"]["state"], .string("applied")); XCTAssertEqual(result["result"]["event"]["id"], selected["id"])
        XCTAssertEqual(base.events[0].fields, original[0].fields); XCTAssertEqual(base.events[1].fields.title, "Future title"); XCTAssertEqual(base.events[2].fields.title, "Future title")
        XCTAssertEqual(base.events[3], original[3]); XCTAssertEqual(base.events[4], original[4]); XCTAssertNotEqual(base.events[1].nativeID, original[1].nativeID)
        XCTAssertEqual(try state.resolve(events[0]["id"].string!, kind: "event").nativeID, original[0].nativeID)
        let sibling = events.first { $0["occurrence"] == .string(original[2].occurrence!) }!
        XCTAssertEqual(try state.resolve(sibling["id"].string!, kind: "event").nativeID, original[2].nativeID)
        XCTAssertEqual(call(broker, "get_event", ["event_id": sibling["id"]])["error"]["code"], .string("event_missing"))
        XCTAssertEqual(commit(broker, preview), result); XCTAssertEqual(base.writeCount, 1)
        XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "1")
        let marker = try JSON.parse(Data(state.rows("SELECT payload FROM executions")[0][0].utf8))
        XCTAssertEqual(marker["future_anchor_id"], events[0]["id"]); XCTAssertEqual(marker["future_boundary"], .string(boundary)); XCTAssertEqual(marker["scope"], .string("future")); XCTAssertEqual(marker["conflict_scope"]["complete"], .bool(false))
        XCTAssertEqual(result["result"]["past_anchor"]["fields"], events[0]["fields"]); try state.verifyAudit()
    }
    func testFirstAnchorBoundaryAndDateEndedRuleDoNotManufactureRecurrence() throws {
        for until in [false, true] {
            let state = try state(), rule = try EventRecurrence(json: .object(["frequency": .string("weekly"), "end": until ? .object(["until": .string("2026-12-01T10:00:00Z")]) : .null])).rawRule
            let base = try fixture(rule: rule); base.events.remove(at: 0)
            let broker = Broker(state: state, backend: base, now: { self.initialNow }), selected = views(broker)[0]
            let result = commit(broker, draft(broker, selected["id"])["result"]["preview"])
            XCTAssertEqual(result["result"]["state"], .string("applied")); XCTAssertEqual(result["result"]["past_anchor"], .null)
            XCTAssertEqual(base.events[0].details["recurrence_rules"], .array([rule])); XCTAssertEqual(base.events[0].nativeID, "future-pattern")
        }
    }
    func testCountMultipleInvalidRulesAndStructuralPatchesFailBeforeIntent() throws {
        for variant in 0..<7 {
            let state = try state(), base = try fixture(); var rule = base.events[0].details["recurrence_rules"].array![0].object!
            switch variant {
            case 0: rule["occurrence_count"] = .int(12)
            case 1: rule["interval"] = .int(0)
            case 2: rule["end_date"] = .string("2026-10-20T10:00:00.000Z")
            case 3: rule["frequency"] = .int(9)
            case 4: rule["days_of_month"] = .array([.int(Int.min)])
            case 5: rule["unknown"] = .bool(true)
            default: break
            }
            for index in base.events.indices { var details = base.events[index].details.object!; details["recurrence_rules"] = .array(variant == 6 ? [.object(rule), .object(rule)] : [.object(rule)]); base.events[index].details = .object(details) }
            let broker = Broker(state: state, backend: base, now: { self.initialNow }), id = views(broker)[1]["id"]
            XCTAssertNotEqual(draft(broker, id)["error"], .null, "rule \(variant)"); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty); XCTAssertEqual(base.writeCount, 0)
        }
        let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), id = views(broker)[1]["id"]
        for patch: [String: JSON] in [[:], ["start": .string(boundary)], ["end": .string(boundary)], ["time_zone": .string("UTC")], ["all_day": .bool(true)], ["recurrence": .null], ["calendar_id": .string("anything")], ["title": .string("Original")]] { XCTAssertNotEqual(draft(broker, id, fields: patch)["error"], .null) }
        XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
    }
    func testPastOngoingDetachedMovedAndUnsupportedAnchorFailBeforeIntent() throws {
        for mode in ["past", "ongoing", "detached", "moved", "meeting", "anchor_alarm", "anchor_location"] {
            let state = try state(), base = try fixture(); var current = initialNow
            var patch: [String: JSON] = ["title": .string("Changed")]
            if mode == "past" { current = try parseDate(boundary).addingTimeInterval(4000) }
            if mode == "ongoing" { current = try parseDate(boundary).addingTimeInterval(1) }
            if mode == "detached" { base.events[1].detached = true }
            if mode == "moved" { base.events[1].fields.start = "2026-11-01T12:00:00.000Z" }
            if mode == "meeting" { base.events[0].hasAttendees = true }
            if mode == "anchor_alarm" { var d = base.events[0].details.object!; d["unsupported_external_alarm"] = .bool(true); base.events[0].details = .object(d) }
            if mode == "anchor_location" { var d = base.events[0].details.object!; d["structured_location"] = .object(["title": .string("Place"), "radius": .string("0.0")]); base.events[0].details = .object(d); patch = ["location": .string("Other")] }
            let broker = Broker(state: state, backend: base, now: { current }), id = views(broker)[1]["id"]
            XCTAssertNotEqual(draft(broker, id, fields: patch)["error"], .null, mode); XCTAssertEqual(base.writeCount, 0); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
        }
    }
    func testExpiryIsCappedByBoundaryAndClockCrossingBeforeClaimDoesNotCharge() throws {
        let state = try state(), base = try fixture(), probe = FutureProbeBackend(base); var current = try parseDate(boundary).addingTimeInterval(-30)
        let broker = Broker(state: state, backend: probe, now: { current }), preview = draft(broker, views(broker)[1]["id"])["result"]["preview"]
        XCTAssertEqual(preview["envelope"]["expires_at"], .string(boundary))
        probe.afterAnchor = { current = try! parseDate(self.boundary) }
        XCTAssertEqual(commit(broker, preview)["error"]["code"], .string("future_boundary_elapsed"))
        XCTAssertEqual(base.writeCount, 0); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty); XCTAssertTrue(try state.rows("SELECT nonce FROM write_safety_claims").isEmpty)
        XCTAssertTrue(try state.commitObservationStatus()["observations"].array!.contains { $0["reason"] == .string("preview_expired") })
    }
    func testClockCrossingAtProviderEntryIsUnknownWithoutMutationAndReplaySurvivesExpiry() throws {
        let state = try state(), base = try fixture(), probe = FutureProbeBackend(base); var current = initialNow
        let broker = Broker(state: state, backend: probe, now: { current }), preview = draft(broker, views(broker)[1]["id"])["result"]["preview"]
        probe.beforeApply = { current = try! parseDate(self.boundary) }
        let result = commit(broker, preview)
        XCTAssertEqual(result["result"]["state"], .string("unknown")); XCTAssertEqual(base.writeCount, 0)
        XCTAssertEqual(commit(broker, preview), result); XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "1")
    }
    func testChangedSelectedOrAnchorAndSignedSemanticTamperingFailBeforeIntent() throws {
        let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), preview = draft(broker, views(broker)[1]["id"])["result"]["preview"]
        for variant in 0..<6 {
            var body = preview["envelope"].object!
            if variant == 0 { var f = body["future"]!.object!; f["boundary"] = .string("2026-11-08T10:00:00.000Z"); body["future"] = .object(f) }
            if variant == 1 { body["recovery"] = .object(["mode": .string("future_default_fields"), "limitations": .array([])]) }
            if variant == 2 { var f = body["future"]!.object!; f["changed_fields"] = .array([.string("title"), .string("title")]); body["future"] = .object(f) }
            if variant == 3 { var f = body["after"]!.object!; f["notes"] = .string("Unmasked"); body["after"] = .object(f) }
            if variant == 4 { body["expires_at"] = .string("2026-11-02T10:00:00.000Z") }
            if variant == 5 { body["after"] = body["before"]!["fields"] }
            XCTAssertNotEqual(commit(broker, try signed(body, state: state))["error"], .null)
        }
        base.events[0].fields.notes = "Changed anchor"
        XCTAssertEqual(commit(broker, preview)["error"]["code"], .string("stale_event")); base.events[0].fields.notes = "Prior notes"
        base.events[1].fields.notes = "Changed selected"
        XCTAssertEqual(commit(broker, preview)["error"]["code"], .string("stale_event")); XCTAssertEqual(base.writeCount, 0); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
    }
    func testPostSplitProviderErrorsAndBadPrefixOrTailStayUnknownWithoutRetry() throws {
        for mode in ["throw", "past_title", "past_time", "past_alarm", "past_rule", "past_created", "past_external", "missing_past", "tail_rule", "tail_time"] {
            let state = try state(), base = try fixture(), probe = FutureProbeBackend(base), broker = Broker(state: state, backend: probe, now: { self.initialNow }), preview = draft(broker, views(broker)[1]["id"])["result"]["preview"]
            if mode == "throw" { base.throwAfterWrite = true } else { probe.corrupt = mode }
            let result = commit(broker, preview)
            XCTAssertEqual(result["result"]["state"], .string("unknown"), mode); XCTAssertEqual(base.writeCount, 1); XCTAssertEqual(commit(broker, preview), result); XCTAssertEqual(base.writeCount, 1)
        }
    }
    func testInverseRestoresOnlyMaskedFieldsAndRawAlarmsWithoutMergingPast() throws {
        let state = try state(), base = try fixture(); var current = initialNow
        let policy = state.directory.appendingPathComponent("recovery-policy.json")
        try JSON.object(["version": .int(1), "retention_days": .int(30)]).data().write(to: policy); XCTAssertEqual(chmod(policy.path, 0o600), 0)
        let alarm: JSON = .object(["absolute_date": .null, "relative_offset": .string("-300.0"), "proximity": .int(0), "structured_location": .null, "type": .int(1), "email_address": .null, "sound_name": .string("Synthetic sound")])
        for index in [0, 1, 2] { var d = base.events[index].details.object!; d["alarms"] = .array([alarm]); base.events[index].details = .object(d) }
        let broker = Broker(state: state, backend: base, now: { current }), events = views(broker), original = base.events
        let preview = draft(broker, events[1]["id"], fields: ["title": .string("Changed"), "alerts": .array([.object(["relative_minutes": .int(-20)])])])["result"]["preview"]
        let result = commit(broker, preview), pastAfter = base.events[0], tailID = base.events[1].nativeID
        let plan = inverse(broker, result["result"]["nonce"]), step = plan["result"]["steps"].array![0], recovery = step["preview"]
        XCTAssertEqual(step["commit_tool"], .string("commit_future_rollback")); XCTAssertEqual(recovery["envelope"]["before"], recovery["envelope"]["future"]["first_anchor"])
        XCTAssertEqual(recovery["envelope"]["rollback"]["alarm_restoration"], .array([alarm])); XCTAssertEqual(recovery["envelope"]["after"]["alerts"], .null)
        let restored = broker.commitReviewedRollback(recovery)
        XCTAssertEqual(restored["result"]["state"], .string("applied")); XCTAssertEqual(base.events[0], pastAfter); XCTAssertEqual(base.events[1].nativeID, tailID)
        XCTAssertEqual(base.events[1].fields, original[1].fields); XCTAssertEqual(base.events[1].details["alarms"], original[1].details["alarms"])
        XCTAssertEqual(commit(broker, recovery, rollback: true), restored); XCTAssertEqual(base.writeCount, 2)
        XCTAssertNotEqual(inverse(broker, result["result"]["nonce"])["error"], .null)
        let second = commit(broker, draft(broker, events[1]["id"], fields: ["notes": .string("Changed again")])["result"]["preview"])
        current = try parseDate(boundary)
        let summary = call(broker, "get_stored_change", ["change_id": second["result"]["nonce"]])["result"]["change"]
        XCTAssertEqual(summary["recovery_eligible"], .bool(false)); XCTAssertEqual(summary["recovery_reason"], .string("future_boundary_elapsed")); XCTAssertNotEqual(inverse(broker, second["result"]["nonce"])["error"], .null)
    }
    func testInverseExternalSegmentChangesAndMixedSelectionsAreRejected() throws {
        let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), events = views(broker)
        let result = commit(broker, draft(broker, events[1]["id"])["result"]["preview"]), nonce = result["result"]["nonce"]
        base.events[1].fields.notes = "External change"
        XCTAssertNotEqual(inverse(broker, nonce)["error"], .null)
        let other = events.first { $0["fields"]["start"] == .string("2026-11-22T10:00:00.000Z") }!
        let later = call(broker, "commit_modify", ["preview": draft(broker, other["id"], fields: ["notes": .string("Other")], scope: "this")["result"]["preview"]])
        XCTAssertEqual(call(broker, "preflight_rollback", ["change_ids": .array([nonce, later["result"]["nonce"]])])["error"]["code"], .string("invalid_selection"))
    }
    func testUnknownFutureBlocksWholeCalendarIncludingNewSplitIDsButOtherCalendarWorks() throws {
        let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), events = views(broker)
        let preview = draft(broker, events[1]["id"])["result"]["preview"]
        base.throwAfterWrite = true; let unknown = commit(broker, preview); base.throwAfterWrite = false
        XCTAssertEqual(unknown["result"]["state"], .string("unknown"))
        let fresh = views(broker), unrelated = fresh.first { $0["fields"]["start"] == .string("2026-11-22T10:00:00.000Z") }!, split = fresh.first { $0["occurrence"] == .string(boundary) }!
        for target in [unrelated, split] {
            let p = draft(broker, target["id"], fields: ["notes": .string("Blocked")], scope: "this")["result"]["preview"]
            XCTAssertEqual(call(broker, "commit_modify", ["preview": p])["error"]["code"], .string("unresolved_write"))
        }
        base.calendarRecords.append(CalendarRecord(nativeID: "different-calendar", title: "Different", source: "Synthetic"))
        let calendar = call(broker, "list_calendars")["result"]["calendars"].array!.first { $0["title"] == .string("Different") }!["id"]
        let create = call(broker, "preflight_change", ["action": .string("create"), "scope": .string("this"), "calendar_id": calendar, "fields": .object(["title": .string("Independent"), "start": .string(boundary), "end": .string("2026-11-01T11:00:00Z")])])["result"]["preview"]
        XCTAssertEqual(call(broker, "commit_create", ["preview": create])["result"]["state"], .string("applied")); XCTAssertEqual(commit(broker, preview), unknown); XCTAssertEqual(base.writeCount, 2)
    }
    func testFutureBoundaryBlocksOrdinaryAndV4RecoveryAcrossAppliedExpiredSplit() throws {
        for series in [false, true] {
            let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), events = views(broker)
            let other = events.first { $0["fields"]["start"] == .string("2026-11-22T10:00:00.000Z") }!
            let p = draft(broker, other["id"], fields: ["notes": .string("Prior unrelated change")], scope: series ? "series" : "this")["result"]["preview"]
            let source = call(broker, series ? "commit_series_modify" : "commit_modify", ["preview": p])
            let future = commit(broker, draft(broker, events[1]["id"])["result"]["preview"]), nonce = future["result"]["nonce"].string!
            XCTAssertEqual(future["result"]["state"], .string("applied"))
            XCTAssertEqual(inverse(broker, source["result"]["nonce"])["error"]["code"], .string("rollback_series_boundary"))
            try state.execute("DELETE FROM execution_keys WHERE nonce=?", [nonce]); try state.execute("UPDATE execution_details SET expired=1 WHERE nonce=?", [nonce])
            XCTAssertEqual(inverse(broker, source["result"]["nonce"])["error"]["code"], .string("rollback_series_boundary"))
        }
    }
    func testInverseCannotSignInterveningSourceReplacementDuringPreflightOrCommit() throws {
        for duringCommit in [false, true] {
            let state = try state(), base = try fixture(), probe = FutureProbeBackend(base), broker = Broker(state: state, backend: probe, now: { self.initialNow })
            let result = commit(broker, draft(broker, views(broker)[1]["id"])["result"]["preview"])
            if duringCommit {
                let recovery = try XCTUnwrap(inverse(broker, result["result"]["nonce"])["result"]["steps"].array?.first?["preview"])
                probe.changeOnGet = probe.getCalls + 2
                XCTAssertEqual(commit(broker, recovery, rollback: true)["error"]["code"], .string("stale_rollback"))
            } else {
                probe.changeOnGet = probe.getCalls + 2
                XCTAssertEqual(inverse(broker, result["result"]["nonce"])["error"]["code"], .string("stale_rollback"))
            }
            XCTAssertEqual(base.writeCount, 1); XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "1")
            XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "1")
        }
    }
    func testFiniteEndSplitPreservesTailEndAndOnlyShortensPrefix() throws {
        let state = try state(), rule = try EventRecurrence(json: .object(["frequency": .string("weekly"), "end": .object(["until": .string("2027-02-01T10:00:00Z")])])).rawRule
        let base = try fixture(rule: rule), broker = Broker(state: state, backend: base, now: { self.initialNow }), selected = views(broker)[1]
        let result = commit(broker, draft(broker, selected["id"])["result"]["preview"])
        XCTAssertEqual(result["result"]["state"], .string("applied")); XCTAssertEqual(base.events[1].details["recurrence_rules"], .array([rule]))
        XCTAssertLessThan(try parseDate(base.events[0].details["recurrence_rules"].array![0]["end_date"].string!), try parseDate(boundary))
    }
    func testFutureUnknownMalformedCompleteFootprintFailsClosed() throws {
        let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), events = views(broker)
        let preview = draft(broker, events[1]["id"])["result"]["preview"]
        base.throwAfterWrite = true; let result = commit(broker, preview); base.throwAfterWrite = false
        let nonce = result["result"]["nonce"].string!
        var marker = try JSON.parse(Data(state.rows("SELECT payload FROM executions WHERE nonce=?", [nonce])[0][0].utf8)).object!, scope = marker["conflict_scope"]!.object!
        scope["complete"] = .bool(true); marker["conflict_scope"] = .object(scope)
        // Corrupt only a synthetic fixture after disabling its immutable-row fence.
        try state.execute("DROP TRIGGER payload_immutable"); try state.execute("UPDATE executions SET payload=? WHERE nonce=?", [try JSON.object(marker).text(), nonce])
        let other = events.first { $0["fields"]["start"] == .string("2026-11-22T10:00:00.000Z") }!
        let next = draft(broker, other["id"], fields: ["notes": .string("Blocked")], scope: "this")["result"]["preview"]
        XCTAssertEqual(call(broker, "commit_modify", ["preview": next])["error"]["code"], .string("unresolved_write")); XCTAssertEqual(base.writeCount, 1)
    }
    func testStoredHistoryEligibilityUsesOnlyJournalAndTimeWithoutProviderReads() throws {
        let state = try state(), base = try fixture(), probe = FutureProbeBackend(base), broker = Broker(state: state, backend: probe, now: { self.initialNow })
        let result = commit(broker, draft(broker, views(broker)[1]["id"])["result"]["preview"]), nonce = result["result"]["nonce"]
        probe.denyReads = true; let before = probe.providerReads
        XCTAssertEqual(call(broker, "get_stored_change", ["change_id": nonce])["result"]["change"]["recovery_eligible"], .bool(true))
        XCTAssertEqual(call(broker, "list_changes")["result"]["changes"].array?.count, 1)
        XCTAssertEqual(probe.providerReads, before)
        XCTAssertNotEqual(inverse(broker, nonce)["error"], .null)
        XCTAssertNotEqual(call(broker, "preflight_rollback", ["all": .bool(true)])["error"], .null)
    }
    func testFutureInverseCannotCrossLaterIndependentSameCalendarIntent() throws {
        let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), events = views(broker)
        let source = commit(broker, draft(broker, events[1]["id"])["result"]["preview"])
        let other = events.first { $0["fields"]["start"] == .string("2026-11-22T10:00:00.000Z") }!
        let later = draft(broker, other["id"], fields: ["notes": .string("Later independent pattern")], scope: "this")["result"]["preview"]
        XCTAssertEqual(call(broker, "commit_modify", ["preview": later])["result"]["state"], .string("applied"))
        XCTAssertEqual(inverse(broker, source["result"]["nonce"])["error"]["code"], .string("rollback_series_boundary"))
    }
    func testFloorThreeUpgradePreservesHistoryAndFrozenThreeWriterRejectsFour() throws {
        let directory: URL, snapshots: [String: [[String]]]
        let tables = ["executions", "execution_details", "execution_keys", "write_safety_claims", "audit", "legacy_audit_manifest", "legacy_audit_details", "identities", "recovery_links", "commit_observations", "commit_observation_clock"]
        do {
            let state = try state(); directory = state.directory
            let base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow })
            let preview = draft(broker, views(broker)[1]["id"], scope: "series")["result"]["preview"]
            XCTAssertEqual(call(broker, "commit_series_modify", ["preview": preview])["result"]["state"], .string("applied"))
            // Synthetic prior-floor fixture; production history is never downgraded.
            try state.execute("UPDATE metadata SET value='3' WHERE key='recovery_storage_version'")
            snapshots = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try state.rows("SELECT * FROM " + $0 + " ORDER BY rowid")) })
        }
        do {
            let state = try StateStore(directory: directory)
            XCTAssertEqual(try state.metadata("recovery_storage_version"), "4")
            for table in tables { XCTAssertEqual(try state.rows("SELECT * FROM " + table + " ORDER BY rowid"), snapshots[table], table) }
            try state.verifyAudit()
        }
        let frozen = "/private/tmp/calendar-scoped-guard-freeze-unoudjav/CalendarHelper"
        guard FileManager.default.isExecutableFile(atPath: frozen) else { throw XCTSkip("Frozen floor-three helper unavailable") }
        XCTAssertEqual(digest(try Data(contentsOf: URL(fileURLWithPath: frozen))), "b44335204801027cd431a57dfa7f1d99b542661d738c9357b57815b5a2900c16")
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: frozen); process.arguments = ["--migrate-recovery", "--state-dir", directory.path]; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertEqual(try JSON.parse(output.fileHandleForReading.readDataToEndOfFile())["error"]["code"], .string("state_version"))
        let state = try StateStore(directory: directory)
        for table in tables { XCTAssertEqual(try state.rows("SELECT * FROM " + table + " ORDER BY rowid"), snapshots[table], table) }
    }
}
