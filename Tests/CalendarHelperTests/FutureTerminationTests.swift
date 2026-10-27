// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import Foundation
import CryptoKit
@testable import CalendarCore

private final class TerminationProbe: CalendarBackend {
    let base: SyntheticBackend
    var failure = ""
    var afterGet: (() -> Void)?
    var beforeQuery: (() -> Void)?
    var beforeRestore: (() -> Void)?
    var beforeRemove: (() -> Void)?
    var afterAnchor: (() -> Void)?
    var denyReads = false
    var overflowQuery = false
    var reads = 0
    var prefixReads = 0
    var mutatePrefixOnRead: Int?
    init(_ base: SyntheticBackend) { self.base = base }
    func calendars() throws -> [CalendarRecord] { reads += 1; if denyReads { throw CoreError("synthetic_denied", "Provider reads disabled") }; return try base.calendars() }
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] { reads += 1; if denyReads { throw CoreError("synthetic_denied", "Provider reads disabled") }; beforeQuery?(); if overflowQuery { return Array(repeating: base.events[2], count: 100_001) }; return try base.query(start: start, end: end, calendarIDs: calendarIDs) }
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord {
        reads += 1; if denyReads { throw CoreError("synthetic_denied", "Provider reads disabled") }
        if occurrence == "2026-10-04T09:00:00.000Z" { prefixReads += 1; if prefixReads == mutatePrefixOnRead, let index = base.events.firstIndex(where: { $0.occurrence == occurrence && $0.nativeID == nativeID }) { base.events[index].fields.notes = "External prefix replacement" } }
        let result = try base.get(nativeID: nativeID, calendarID: calendarID, occurrence: occurrence, knownStart: knownStart); afterGet?(); return result
    }
    func firstSeriesOccurrence(for selected: EventRecord) throws -> EventRecord {
        reads += 1; if denyReads { throw CoreError("synthetic_denied", "Provider reads disabled") }
        if selected.occurrence == "2026-10-04T09:00:00.000Z" {
            prefixReads += 1
            if prefixReads == mutatePrefixOnRead, let index = base.events.firstIndex(where: { $0.occurrence == selected.occurrence && $0.nativeID == selected.nativeID }) { base.events[index].fields.notes = "External prefix replacement" }
        }
        let record = try base.firstSeriesOccurrence(for: selected); afterAnchor?(); return record
    }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? { try base.apply(action: action, calendarID: calendarID, existing: existing, fields: fields) }
    func applyFutureFields(selected: EventRecord, originalAnchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?, boundaryNow: () -> Date) throws -> FutureWriteResult { try base.applyFutureFields(selected: selected, originalAnchor: originalAnchor, fields: fields, changedFields: changedFields, restoredAlarms: restoredAlarms, boundaryNow: boundaryNow) }
    func applySeriesFields(anchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?) throws -> EventRecord { try base.applySeriesFields(anchor: anchor, fields: fields, changedFields: changedFields, restoredAlarms: restoredAlarms) }
    func removeFuture(selected: EventRecord, originalAnchor: EventRecord, boundaryNow: () -> Date) throws -> FutureRemovalResult {
        beforeRemove?()
        let result = try base.removeFuture(selected: selected, originalAnchor: originalAnchor, boundaryNow: boundaryNow)
        if failure == "surviving_boundary" { base.events.append(selected) }
        if failure == "missing_prefix" { return FutureRemovalResult() }
        if failure == "prefix_title" { var past = result.pastAnchor!; past.fields.title = "Unexpected"; return FutureRemovalResult(pastAnchor: past) }
        if failure == "prefix_rule" { var past = result.pastAnchor!, d = past.details.object!, rule = d["recurrence_rules"]!.array![0].object!; rule["interval"] = .int(9); d["recurrence_rules"] = .array([.object(rule)]); past.details = .object(d); return FutureRemovalResult(pastAnchor: past) }
        return result
    }
    func restoreFutureTail(calendarID: String, originalSelected: EventRecord, expectedPrefix: EventRecord?, fields: EventFields, details: JSON, availability: String) throws -> EventRecord {
        beforeRestore?()
        var result = try base.restoreFutureTail(calendarID: calendarID, originalSelected: originalSelected, expectedPrefix: expectedPrefix, fields: fields, details: details, availability: availability)
        if failure == "copy_alarm" { var d = result.details.object!; d["alarms"] = .array([try EventAlert(json: .object(["relative_minutes": .int(-10)])).rawAlarm]); result.details = .object(d) }
        if failure == "copy_prefix" { base.events[0].fields.notes = "Unexpected prefix edit" }
        if failure == "copy_existing" { return base.events.first { $0.nativeID == "previously-known-copy" }! }
        return result
    }
}

final class FutureTerminationTests: XCTestCase {
    private var directories: [URL] = []
    private let boundary = "2026-11-01T10:00:00.000Z"
    private let initialNow = try! parseDate("2026-10-25T09:00:00.000Z")
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at: directory) }; super.tearDown() }
    private func state() throws -> StateStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-termination-fixture-" + UUID().uuidString); directories.append(directory)
        let state = try StateStore(directory: directory); try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "c", count: 64)); return state
    }
    private func fixture(rule: EventRecurrence? = nil) throws -> SyntheticBackend {
        let recurrence = try rule ?? EventRecurrence(json: .object(["frequency": .string("weekly")]))
        let starts = ["2026-10-04T09:00:00.000Z", "2026-10-25T10:00:00.000Z", boundary, "2026-11-08T10:00:00.000Z", "2026-11-15T10:00:00.000Z", "2026-11-22T10:00:00.000Z"]
        return SyntheticBackend(events: try starts.enumerated().map { index, start in
            EventRecord(nativeID: index == 5 ? "other-pattern" : "stopped-pattern", calendarNativeID: "synthetic-calendar", occurrence: start,
                        fields: EventFields(title: "Retained title", start: start, end: iso(try parseDate(start).addingTimeInterval(3600)), timeZone: "Europe/London", allDay: false, location: "Place", notes: "Retained notes"), recurring: true, detached: index == 4,
                        details: .object(["recurrence_rules": .array([recurrence.rawRule]), "alarms": .array([]), "url": .string("https://example.invalid/retained"), "structured_location": .null]))
        })
    }
    private func call(_ broker: Broker, _ operation: String, _ arguments: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(operation), "arguments": .object(arguments)])) }
    private func views(_ broker: Broker) -> [JSON] { call(broker, "query_events", ["start": .string("2026-10-01T00:00:00Z"), "end": .string("2026-12-10T00:00:00Z")])["result"]["events"].array! }
    private func cutoff(_ day: String = "2026-11-01") -> JSON { .object(["date": .string(day), "time_zone": .string("Europe/London")]) }
    private func draft(_ broker: Broker, _ id: JSON, cutoff value: JSON? = nil) -> JSON { call(broker, "preflight_change", ["action": .string("delete"), "scope": .string("future"), "event_id": id, "cutoff": value ?? cutoff()]) }
    private func commit(_ broker: Broker, _ preview: JSON, restore: Bool = false) -> JSON { call(broker, restore ? "commit_future_restore" : "commit_future_delete", ["preview": preview]) }
    private func rollback(_ broker: Broker, _ nonce: JSON) -> JSON { call(broker, "preflight_rollback", ["change_ids": .array([nonce])]) }
    private func sign(_ envelope: [String: JSON], _ state: StateStore) throws -> JSON {
        let body = JSON.object(envelope), key = SymmetricKey(data: Data(base64Encoded: try state.metadata("signing_key")!)!)
        return .object(["envelope": body, "authentication_tag": .string(Data(HMAC<SHA256>.authenticationCode(for: try body.data(), using: key)).base64EncodedString())])
    }
    func testExactCutoffBoundarySingleDeletePreservesPrefixAndDetachedSurvivor() throws {
        for instant in [false, true] {
            let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), events = views(broker), original = base.events
            let value = instant ? JSON.object(["at": .string("2026-11-01T11:00:00+01:00")]) : cutoff()
            let step = draft(broker, events[0]["id"], cutoff: value)["result"], preview = step["preview"], envelope = preview["envelope"]
            XCTAssertEqual(envelope["version"], .int(6)); XCTAssertEqual(step["commit_tool"], .string("commit_future_delete")); XCTAssertEqual(envelope["future"]["boundary"], .string(boundary))
            XCTAssertEqual(envelope["before"], events[2]); XCTAssertEqual(envelope["future"]["reference"], events[0]); XCTAssertEqual(envelope["future"]["removes_entire_current_pattern"], .bool(false)); XCTAssertEqual(envelope["recovery"], Broker.terminationRecovery)
            XCTAssertEqual(call(broker, "future_termination_capabilities")["result"], Broker.futureTerminationCapabilities)
            for tool in ["commit_delete", "commit_modify", "commit_create", "commit_rollback", "commit_future_modify", "commit_future_rollback", "commit_series_modify", "commit_series_rollback", "commit_future_restore"] { XCTAssertNotEqual(call(broker, tool, ["preview": preview])["error"], .null) }
            let result = commit(broker, preview)
            XCTAssertEqual(result["result"]["state"], .string("applied")); XCTAssertEqual(base.writeCount, 1); XCTAssertEqual(base.events.count, 4)
            XCTAssertEqual(base.events[0].fields, original[0].fields); XCTAssertEqual(base.events[1].fields, original[1].fields)
            XCTAssertTrue(base.events.contains(original[4])); XCTAssertTrue(base.events.contains(original[5])); XCTAssertFalse(base.events.contains { $0.occurrence == boundary })
            XCTAssertEqual(commit(broker, preview), result); XCTAssertEqual(base.writeCount, 1)
            XCTAssertEqual(try state.rows("SELECT action FROM write_safety_claims"), [["delete"]]); XCTAssertEqual(try state.resolve(events[2]["id"].string!, kind: "event").nativeID, "stopped-pattern")
            let marker = try JSON.parse(Data(state.rows("SELECT payload FROM executions")[0][0].utf8))
            XCTAssertEqual(marker["future_kind"], .string("termination")); XCTAssertEqual(marker["conflict_scope"]["complete"], .bool(false)); try state.verifyAudit()
        }
    }
    func testCutoffLocalMidnightDSTAndStrictDateForms() throws {
        XCTAssertEqual(iso(try FutureCutoff(cutoff("2026-10-25")).start), "2026-10-24T23:00:00.000Z")
        XCTAssertEqual(iso(try FutureCutoff(cutoff("2026-03-29")).start), "2026-03-29T00:00:00.000Z")
        for value: JSON in [.object(["date": .string("0001-01-01"), "time_zone": .string("Asia/Tokyo")]), .object(["at": .string("9999-12-31T00:00:00Z")]), .object(["date": .string("9999-01-01"), "time_zone": .string("Europe/London")]), .object(["date": .string("2026-02-30"), "time_zone": .string("Europe/London")]), .object(["date": .string("2026-11-01")]), .object(["at": .string("2026-11-01T10:00:00")]), .object(["date": .string("2011-12-30"), "time_zone": .string("Pacific/Apia")]), .object(["date": .string("2026-11-01"), "time_zone": .string("America/Havana")]), .object(["date": .string("2026-11-01"), "time_zone": .string("Missing/Zone")]), .object(["at": .string(boundary), "date": .string("2026-11-01")])] { XCTAssertThrowsError(try FutureCutoff(value)) }
    }
    func testSkippedCutoffUsesNextDefaultButKnownDetachedBeforeItIsRejected() throws {
        let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), id = views(broker)[0]["id"]
        XCTAssertEqual(draft(broker, id, cutoff: cutoff("2026-11-02"))["result"]["preview"]["envelope"]["future"]["boundary"], .string("2026-11-08T10:00:00.000Z"))
        base.events[4].fields.start = "2026-11-03T10:00:00.000Z"; base.events[4].fields.end = "2026-11-03T11:00:00.000Z"
        XCTAssertEqual(draft(broker, id, cutoff: cutoff("2026-11-02"))["error"]["code"], .string("unsupported_detached_boundary")); XCTAssertEqual(base.writeCount, 0)
        XCTAssertEqual(draft(broker, id, cutoff: cutoff("2028-01-01"))["error"]["code"], .string("future_boundary_unavailable"))
    }
    func testElapsedEarliestAmbiguousDetachedAndUnsupportedPatternRejectBeforeIntent() throws {
        for mode in ["past", "ongoing", "ambiguous", "detached_ref", "count", "complex", "nil_zone", "meeting", "multi"] {
            let state = try state(), base = try fixture(); var current = initialNow
            if mode == "past" { current = try parseDate(boundary).addingTimeInterval(7200) }
            if mode == "ongoing" { current = try parseDate(boundary).addingTimeInterval(10) }
            if mode == "ambiguous" { base.events.append(base.events[2]) }
            if mode == "detached_ref" { base.events[0].detached = true }
            if mode == "nil_zone" { for index in 0..<5 { base.events[index].fields.timeZone = nil } }
            if mode == "meeting" { base.events[2].hasOrganizer = true }
            if ["count", "complex", "multi"].contains(mode) {
                for index in 0..<5 { var d = base.events[index].details.object!, r = d["recurrence_rules"]!.array![0].object!; if mode == "count" { r["occurrence_count"] = .int(10) }; if mode == "complex" { r["set_positions"] = .array([.int(1)]) }; d["recurrence_rules"] = .array(mode == "multi" ? [.object(r), .object(r)] : [.object(r)]); base.events[index].details = .object(d) }
            }
            let broker = Broker(state: state, backend: base, now: { current }), id = views(broker)[0]["id"]
            XCTAssertNotEqual(draft(broker, id)["error"], .null, mode); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty); XCTAssertEqual(base.writeCount, 0)
        }
    }
    func testTypedCopyPhaseRejectsMonthlyLeapDayAndDSTNormalization() throws {
        func pair(_ a: String, _ b: String, frequency: String, zone: String = "Europe/London", endOffset: Double = 3600) throws -> (EventRecord, EventRecord) {
            let rule = try EventRecurrence(json: .object(["frequency": .string(frequency)])), details: JSON = .object(["recurrence_rules": .array([rule.rawRule])])
            let anchor = EventRecord(nativeID: "phase", calendarNativeID: "calendar", occurrence: a, fields: EventFields(title: "Phase", start: a, end: iso(try parseDate(a).addingTimeInterval(endOffset)), timeZone: zone, allDay: false), recurring: true, details: details)
            var selected = anchor; selected.occurrence = b; selected.fields.start = b; selected.fields.end = iso(try parseDate(b).addingTimeInterval(endOffset)); return (anchor, selected)
        }
        for item in [try pair("2026-01-31T10:00:00.000Z", "2026-02-28T10:00:00.000Z", frequency: "monthly"), try pair("2024-02-29T10:00:00.000Z", "2025-02-28T10:00:00.000Z", frequency: "yearly"), try pair("2026-03-22T01:30:00.000Z", "2026-03-29T01:30:00.000Z", frequency: "weekly")] { XCTAssertThrowsError(try FutureTerminationPattern.copyRecurrence(selected: item.1, anchor: item.0, now: .distantPast)) }
        let good = try pair("2026-10-04T09:00:00.000Z", boundary, frequency: "weekly")
        XCTAssertNoThrow(try FutureTerminationPattern.copyRecurrence(selected: good.1, anchor: good.0, now: initialNow))
        var badDuration = good.1; badDuration.fields.end = "2026-11-02T11:00:00.000Z"
        XCTAssertThrowsError(try FutureTerminationPattern.copyRecurrence(selected: badDuration, anchor: good.0, now: initialNow))
    }
    func testWholeNotStartedPatternAndIndependentCopyDoNotRebindOriginalIDs() throws {
        let state = try state(), base = try fixture(); base.events.removeFirst(2)
        let broker = Broker(state: state, backend: base, now: { self.initialNow }), selected = views(broker)[0]
        let preview = draft(broker, selected["id"])["result"]["preview"]
        XCTAssertEqual(preview["envelope"]["future"]["removes_entire_current_pattern"], .bool(true))
        let result = commit(broker, preview); XCTAssertEqual(result["result"]["state"], .string("applied")); XCTAssertEqual(result["result"]["past_anchor"], .null)
        let step = try XCTUnwrap(rollback(broker, result["result"]["nonce"])["result"]["steps"].array?.first)
        let restored = commit(broker, step["preview"], restore: true)
        XCTAssertEqual(restored["result"]["state"], .string("applied")); XCTAssertNotEqual(restored["result"]["event"]["id"], selected["id"])
        XCTAssertEqual(try state.resolve(selected["id"].string!, kind: "event").nativeID, "stopped-pattern"); XCTAssertEqual(base.writeCount, 2)
    }
    func testRestoreAfterBoundaryPreservesRawMetadataLongTextAndTruncatedPrefix() throws {
        let state = try state(), base = try fixture(); var current = initialNow
        let policy = state.directory.appendingPathComponent("recovery-policy.json"); try JSON.object(["version": .int(1), "retention_days": .int(30)]).data().write(to: policy); XCTAssertEqual(chmod(policy.path, 0o600), 0)
        let alarm: JSON = .object(["absolute_date": .null, "relative_offset": .string("-300.0"), "proximity": .int(0), "structured_location": .null, "type": .int(1), "email_address": .null, "sound_name": .string("Synthetic sound")])
        base.events[2].fields.notes = String(repeating: "Retained ", count: 1400)
        var details = base.events[2].details.object!; details["alarms"] = .array([alarm]); details["structured_location"] = .object(["title": .string("Retained place"), "radius": .string("0.0")]); base.events[2].details = .object(details)
        let broker = Broker(state: state, backend: base, now: { current }), events = views(broker), original = base.events[2]
        let result = commit(broker, draft(broker, events[0]["id"])["result"]["preview"]), prefix = base.events[0]
        current = try parseDate(boundary).addingTimeInterval(86400)
        let plan = rollback(broker, result["result"]["nonce"]), step = try XCTUnwrap(plan["result"]["steps"].array?.first)
        XCTAssertEqual(step["commit_tool"], .string("commit_future_restore")); XCTAssertEqual(step["preview"]["envelope"]["after"]["start"], .string(boundary)); XCTAssertEqual(step["preview"]["envelope"]["before"], .null)
        XCTAssertEqual(step["preview"]["envelope"]["rollback"]["restoration"]["details"]["alarms"], .array([alarm]))
        for tool in ["commit_create", "commit_delete", "commit_rollback", "commit_future_delete", "commit_future_rollback", "commit_series_rollback"] { XCTAssertNotEqual(call(broker, tool, ["preview": step["preview"]])["error"], .null) }
        let restored = broker.commitReviewedRollback(step["preview"])
        XCTAssertEqual(restored["result"]["state"], .string("applied")); XCTAssertEqual(base.events[0], prefix)
        let created = base.events.last!; XCTAssertNotEqual(created.nativeID, original.nativeID); XCTAssertEqual(created.fields, original.fields); XCTAssertEqual(created.details["alarms"], original.details["alarms"]); XCTAssertEqual(created.details["url"], original.details["url"]); XCTAssertEqual(created.details["structured_location"], original.details["structured_location"])
        XCTAssertEqual(try state.rows("SELECT action FROM write_safety_claims"), [["delete"]]); XCTAssertEqual(commit(broker, step["preview"], restore: true), restored); XCTAssertEqual(base.writeCount, 2)
        XCTAssertNotEqual(rollback(broker, result["result"]["nonce"])["error"], .null)
    }
    func testStalePrefixRegrowthLaterIntentAndInterveningRecoveryReadsFailClosed() throws {
        for mode in ["prefix", "boundary", "later", "intervening"] {
            let state = try state(), base = try fixture(), probe = TerminationProbe(base), broker = Broker(state: state, backend: probe, now: { self.initialNow }), events = views(broker), originalBoundary = base.events[2]
            let result = commit(broker, draft(broker, events[0]["id"])["result"]["preview"])
            if mode == "prefix" { base.events[0].fields.notes = "External change" }
            if mode == "boundary" { base.events.append(originalBoundary) }
            if mode == "later" {
                let other = events.last!["id"], p = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("this"), "event_id": other, "fields": .object(["notes": .string("Later")])])["result"]["preview"]
                XCTAssertEqual(call(broker, "commit_modify", ["preview": p])["result"]["state"], .string("applied"))
            }
            if mode == "intervening" {
                let recovery = try XCTUnwrap(rollback(broker, result["result"]["nonce"])["result"]["steps"].array?.first?["preview"])
                probe.mutatePrefixOnRead = probe.prefixReads + 2
                XCTAssertNotEqual(commit(broker, recovery, restore: true)["error"], .null)
            } else { XCTAssertNotEqual(rollback(broker, result["result"]["nonce"])["error"], .null, mode) }
            XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], mode == "later" ? "2" : "1")
        }
    }
    func testRemovalAndCopyFailuresStayUnknownWithCalendarWideGuardAndPinnedSource() throws {
        for mode in ["throw", "surviving_boundary", "missing_prefix", "prefix_title", "prefix_rule", "copy_throw", "copy_alarm", "copy_prefix", "copy_existing"] {
            let state = try state(), base = try fixture(), probe = TerminationProbe(base), broker = Broker(state: state, backend: probe, now: { self.initialNow })
            if mode == "copy_existing" { var existing = base.events[2]; existing.nativeID = "previously-known-copy"; base.events.append(existing) }
            let events = views(broker), preview = draft(broker, events[0]["id"])["result"]["preview"]
            if mode == "throw" { base.throwAfterWrite = true }
            if !mode.hasPrefix("copy_") { probe.failure = mode }
            let deleted = commit(broker, preview)
            var unknown = deleted, retryPreview = preview, restore = false
            if mode.hasPrefix("copy_") {
                let step = try XCTUnwrap(rollback(broker, deleted["result"]["nonce"])["result"]["steps"].array?.first)
                probe.failure = mode; if mode == "copy_throw" { base.throwAfterWrite = true }
                retryPreview = step["preview"]; restore = true; unknown = commit(broker, retryPreview, restore: true)
                XCTAssertTrue(try state.recoveryHeldNonces().contains(deleted["result"]["nonce"].string!))
            }
            XCTAssertEqual(unknown["result"]["state"], .string("unknown"), mode); XCTAssertEqual(commit(broker, retryPreview, restore: restore), unknown)
            let p = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("this"), "event_id": events.last!["id"], "fields": .object(["notes": .string("Blocked")])])["result"]["preview"]
            let blocked = call(broker, "commit_modify", ["preview": p])
            XCTAssertEqual(blocked["error"]["code"], .string("unresolved_write")); XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "1")
            if mode == "throw" {
                let message = try XCTUnwrap(blocked["error"]["message"].string)
                for tool in ["list_unresolved_changes", "get_stored_change", "get_change_status", "preflight_reconciliation", "commit_reconciliation"] { XCTAssertTrue(message.contains(tool)) }
                XCTAssertTrue(message.contains("can hold the entire calendar")); XCTAssertTrue(message.contains("refresh the calendar plugin tool definitions"))
                XCTAssertFalse(message.contains("reconcile locally"))
                XCTAssertEqual(call(broker, "list_unresolved_changes")["result"]["changes"].array?.count, 1)
                XCTAssertEqual(call(broker, "get_change_status", ["nonce": unknown["result"]["nonce"]])["result"]["state"], .string("unknown"))
                XCTAssertEqual(call(broker, "reconciliation_capabilities")["result"]["user_assessment"], .bool(true))
            }
        }
    }
    func testSharedOpaqueReferenceCannotProduceConflictingSnapshotsAndCommitRechecksSelection() throws {
        let state = try state(), base = try fixture(), probe = TerminationProbe(base), broker = Broker(state: state, backend: probe, now: { self.initialNow }), events = views(broker)
        probe.beforeQuery = { base.events[2].fields.notes = "Changed during selection" }
        XCTAssertEqual(draft(broker, events[2]["id"])["error"]["code"], .string("stale_event"))
        probe.beforeQuery = nil
        let preview = draft(broker, events[0]["id"])["result"]["preview"]
        base.events[2].fields.title = "Changed boundary"
        XCTAssertEqual(commit(broker, preview)["error"]["code"], .string("stale_event"))
        base.events[2].fields.title = "Retained title"
        base.events[0].fields.notes = "Changed reference and anchor"
        XCTAssertEqual(commit(broker, preview)["error"]["code"], .string("stale_event"))
        XCTAssertEqual(base.writeCount, 0); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
    }
    func testWeeklyExplicitIntervalAndAllDayCalendarDurationCanBeCopied() throws {
        let rule = try EventRecurrence(json: .object(["frequency": .string("weekly"), "interval": .int(2), "days_of_week": .array([.int(1), .int(4)]), "end": .object(["until": .string("2027-12-01T10:00:00Z")])]))
        let base = try fixture(rule: rule)
        XCTAssertEqual(try FutureTerminationPattern.copyRecurrence(selected: base.events[2], anchor: base.events[0], now: initialNow), rule)
        var anchor = base.events[0], selected = base.events[2]
        anchor.occurrence = "2026-03-22T00:00:00.000Z"; anchor.fields.start = anchor.occurrence!; anchor.fields.end = "2026-03-23T00:00:00.000Z"; anchor.fields.allDay = true
        selected.occurrence = "2026-03-29T00:00:00.000Z"; selected.fields.start = selected.occurrence!; selected.fields.end = "2026-03-29T23:00:00.000Z"; selected.fields.allDay = true
        XCTAssertNoThrow(try FutureTerminationPattern.copyRecurrence(selected: selected, anchor: anchor, now: .distantPast))
        XCTAssertNoThrow(try FutureTerminationPattern.validateRetainedFields(selected.fields))
        var d = selected.details.object!, raw = rule.rawRule.object!; raw["first_day"] = .int(1); d["recurrence_rules"] = .array([.object(raw)]); selected.details = .object(d); anchor.details = .object(d)
        XCTAssertThrowsError(try FutureTerminationPattern.copyRecurrence(selected: selected, anchor: anchor, now: .distantPast))
    }
    func testPositiveDailyMonthlyAndYearlyCopyPhaseAndCompleteQueryOverflow() throws {
        for (frequency, interval, first, later) in [("daily", 3, "2026-01-01T10:00:00.000Z", "2026-01-04T10:00:00.000Z"), ("monthly", 2, "2026-01-31T10:00:00.000Z", "2026-03-31T09:00:00.000Z"), ("yearly", 4, "2024-02-29T10:00:00.000Z", "2028-02-29T10:00:00.000Z")] {
            let rule = try EventRecurrence(json: .object(["frequency": .string(frequency), "interval": .int(interval)])), details: JSON = .object(["recurrence_rules": .array([rule.rawRule])])
            let anchor = EventRecord(nativeID: "phase", calendarNativeID: "synthetic", occurrence: first, fields: EventFields(title: "Phase", start: first, end: iso(try parseDate(first).addingTimeInterval(3600)), timeZone: "Europe/London", allDay: false), recurring: true, details: details)
            var selected = anchor; selected.occurrence = later; selected.fields.start = later; selected.fields.end = iso(try parseDate(later).addingTimeInterval(3600))
            XCTAssertEqual(try FutureTerminationPattern.copyRecurrence(selected: selected, anchor: anchor, now: .distantPast), rule)
        }
        let state = try state(), base = try fixture(), probe = TerminationProbe(base), broker = Broker(state: state, backend: probe, now: { self.initialNow }), id = views(broker)[0]["id"]
        probe.overflowQuery = true
        XCTAssertEqual(draft(broker, id)["error"]["code"], .string("future_selection_too_large")); XCTAssertEqual(base.writeCount, 0); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
        let reads = probe.reads
        XCTAssertNotEqual(draft(broker, id, cutoff: .object(["at": .string("9999-12-31T00:00:00Z")]))["error"], .null); XCTAssertEqual(probe.reads, reads)
    }
    func testProviderEntryPrefixChangeOrReappearingBoundaryPreventsNewCopy() throws {
        for reappears in [false, true] {
            let state = try state(), base = try fixture(), probe = TerminationProbe(base), broker = Broker(state: state, backend: probe, now: { self.initialNow }), selected = base.events[2]
            let deleted = commit(broker, draft(broker, views(broker)[0]["id"])["result"]["preview"])
            let step = try XCTUnwrap(rollback(broker, deleted["result"]["nonce"])["result"]["steps"].array?.first)
            probe.beforeRestore = { if reappears { base.events.append(selected) } else { base.events[0].fields.notes = "Intervening provider-entry prefix change" } }
            let unknown = commit(broker, step["preview"], restore: true)
            XCTAssertEqual(unknown["result"]["state"], .string("unknown")); XCTAssertEqual(base.writeCount, 1)
            XCTAssertEqual(commit(broker, step["preview"], restore: true), unknown); XCTAssertTrue(try state.recoveryHeldNonces().contains(deleted["result"]["nonce"].string!))
        }
    }
    func testProviderReadDelayCannotClaimExpiredDeleteOrIndependentCopyReview() throws {
        for restore in [false, true] {
            let state = try state(), base = try fixture(), probe = TerminationProbe(base); var current = initialNow
            let broker = Broker(state: state, backend: probe, now: { current }), preview = draft(broker, views(broker)[0]["id"])["result"]["preview"]
            if restore {
                let deleted = commit(broker, preview), recovery = try XCTUnwrap(rollback(broker, deleted["result"]["nonce"])["result"]["steps"].array?.first?["preview"])
                probe.afterAnchor = { current = self.initialNow.addingTimeInterval(601) }
                XCTAssertEqual(commit(broker, recovery, restore: true)["error"]["code"], .string("preview_expired"))
            } else {
                probe.afterAnchor = { current = self.initialNow.addingTimeInterval(601) }
                XCTAssertEqual(commit(broker, preview)["error"]["code"], .string("preview_expired"))
            }
            XCTAssertEqual(base.writeCount, restore ? 1 : 0)
            XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], restore ? "1" : "0")
            XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], restore ? "1" : "0")
        }
    }
    func testClockCrossingBeforeClaimAndImmediatelyBeforeRemoval() throws {
        for afterClaim in [false, true] {
            let state = try state(), base = try fixture(), probe = TerminationProbe(base); var current = try parseDate(boundary).addingTimeInterval(-30)
            let broker = Broker(state: state, backend: probe, now: { current }), preview = draft(broker, views(broker)[0]["id"])["result"]["preview"]
            XCTAssertEqual(preview["envelope"]["expires_at"], .string(boundary))
            if afterClaim { probe.beforeRemove = { current = try! parseDate(self.boundary) } } else { probe.afterAnchor = { current = try! parseDate(self.boundary) } }
            let result = commit(broker, preview)
            if afterClaim { XCTAssertEqual(result["result"]["state"], .string("unknown")); XCTAssertEqual(commit(broker, preview), result) } else { XCTAssertNotEqual(result["error"], .null) }
            XCTAssertEqual(base.writeCount, 0); XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], afterClaim ? "1" : "0")
        }
    }
    func testSignedSemanticTamperingAndHistoryNeverReadProvider() throws {
        let state = try state(), base = try fixture(), probe = TerminationProbe(base), broker = Broker(state: state, backend: probe, now: { self.initialNow }), preview = draft(broker, views(broker)[0]["id"])["result"]["preview"]
        for variant in 0..<5 {
            var body = preview["envelope"].object!, future = body["future"]!.object!
            if variant == 0 { future["boundary"] = .string("2026-11-08T10:00:00.000Z") }
            if variant == 1 { future["removes_entire_current_pattern"] = .bool(true) }
            if variant == 2 { future["copy_recurrence"] = .object(["frequency": .string("daily")]) }
            if variant == 3 { future["cutoff"] = cutoff("2026-11-02") }
            if variant == 4 { body["recovery"] = .object(["mode": .string("independent_tail_copy"), "limitations": .array([])]) }
            body["future"] = .object(future); XCTAssertNotEqual(commit(broker, try sign(body, state))["error"], .null)
        }
        let result = commit(broker, preview); probe.denyReads = true; let reads = probe.reads
        XCTAssertEqual(call(broker, "get_stored_change", ["change_id": result["result"]["nonce"]])["result"]["change"]["recovery_eligible"], .bool(true))
        XCTAssertEqual(call(broker, "list_changes")["result"]["changes"].array?.count, 1); XCTAssertEqual(probe.reads, reads)
        XCTAssertNotEqual(rollback(broker, result["result"]["nonce"])["error"], .null); XCTAssertEqual(base.writeCount, 1)
    }
    func testOtherCalendarIntentAllowsIndependentCopyWhileUnknownTerminationBlocksOnlyOriginalCalendar() throws {
        for makeUnknown in [false, true] {
            let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), events = views(broker)
            let preview = draft(broker, events[0]["id"])["result"]["preview"]
            base.throwAfterWrite = makeUnknown; let deleted = commit(broker, preview); base.throwAfterWrite = false
            base.calendarRecords.append(CalendarRecord(nativeID: "other-calendar", title: "Independent calendar", source: "Synthetic"))
            let calendar = call(broker, "list_calendars")["result"]["calendars"].array!.first { $0["title"] == .string("Independent calendar") }!["id"]
            let create = call(broker, "preflight_change", ["action": .string("create"), "scope": .string("this"), "calendar_id": calendar, "fields": .object(["title": .string("Independent"), "start": .string(boundary), "end": .string("2026-11-01T11:00:00Z")])])["result"]["preview"]
            XCTAssertEqual(call(broker, "commit_create", ["preview": create])["result"]["state"], .string("applied"))
            if makeUnknown { XCTAssertEqual(deleted["result"]["state"], .string("unknown")); XCTAssertEqual(commit(broker, preview), deleted) }
            else {
                let step = try XCTUnwrap(rollback(broker, deleted["result"]["nonce"])["result"]["steps"].array?.first)
                XCTAssertEqual(commit(broker, step["preview"], restore: true)["result"]["state"], .string("applied"))
            }
            XCTAssertEqual(try state.rows("SELECT action FROM write_safety_claims"), [["delete"]])
        }
    }
    func testExpiredTerminationAndIndependentCopyKeepRecoveryBoundaryAndMixedSelectionsReject() throws {
        let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), events = views(broker)
        let ordinaryPreview = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("this"), "event_id": events.last!["id"], "fields": .object(["notes": .string("Before termination")])])["result"]["preview"]
        let ordinary = call(broker, "commit_modify", ["preview": ordinaryPreview]), deleted = commit(broker, draft(broker, events[0]["id"])["result"]["preview"])
        XCTAssertEqual(call(broker, "preflight_rollback", ["change_ids": .array([ordinary["result"]["nonce"], deleted["result"]["nonce"]])])["error"]["code"], .string("invalid_selection"))
        XCTAssertEqual(rollback(broker, ordinary["result"]["nonce"])["error"]["code"], .string("rollback_series_boundary"))
        let step = try XCTUnwrap(rollback(broker, deleted["result"]["nonce"])["result"]["steps"].array?.first), copied = commit(broker, step["preview"], restore: true)
        XCTAssertEqual(copied["result"]["state"], .string("applied"))
        for value in [deleted["result"]["nonce"], copied["result"]["nonce"]] {
            let nonce = value.string!; try state.execute("DELETE FROM execution_keys WHERE nonce=?", [nonce]); try state.execute("UPDATE execution_details SET expired=1 WHERE nonce=?", [nonce])
        }
        XCTAssertEqual(rollback(broker, ordinary["result"]["nonce"])["error"]["code"], .string("rollback_series_boundary"))
        XCTAssertNotEqual(rollback(broker, deleted["result"]["nonce"])["error"], .null)
    }
    func testFloorFourUpgradePreservesHistoryAndFrozenFourRejectsFive() throws {
        let directory: URL, history: [String: [[String]]], identityMetadata: [[String]]
        let tables = ["executions", "execution_details", "execution_keys", "write_safety_claims", "audit", "legacy_audit_manifest", "legacy_audit_details", "identities", "recovery_links", "commit_observations", "commit_observation_clock"]
        do {
            let state = try state(); directory = state.directory
            let base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow }), events = views(broker)
            let p = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("future"), "event_id": events[2]["id"], "fields": .object(["title": .string("Prior v5")])])["result"]["preview"]
            XCTAssertEqual(call(broker, "commit_future_modify", ["preview": p])["result"]["state"], .string("applied"))
            try state.execute("UPDATE metadata SET value='4' WHERE key='recovery_storage_version'")
            history = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try state.rows("SELECT * FROM " + $0 + " ORDER BY rowid")) })
            identityMetadata = try state.rows("SELECT * FROM metadata WHERE key NOT IN ('recovery_storage_version','recovery_clock_highwater') ORDER BY key")
        }
        do { let state = try StateStore(directory: directory); XCTAssertEqual(try state.metadata("recovery_storage_version"), "7"); for table in tables { XCTAssertEqual(try state.rows("SELECT * FROM " + table + " ORDER BY rowid"), history[table]) }; XCTAssertEqual(try state.rows("SELECT * FROM metadata WHERE key NOT IN ('recovery_storage_version','recovery_clock_highwater') ORDER BY key"), identityMetadata) }
        let frozen = "/private/tmp/calendar-future-v5-freeze-p9j0kpd_/CalendarHelper"
        guard FileManager.default.isExecutableFile(atPath: frozen) else { throw XCTSkip("Frozen v5 floor-four helper unavailable") }
        XCTAssertEqual(digest(try Data(contentsOf: URL(fileURLWithPath: frozen))), "4b7895c799f0be55c6b4052df5e4bfa522e3c396a551ddec77c68c273acaf347")
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: frozen); process.arguments = ["--migrate-recovery", "--state-dir", directory.path]; process.standardOutput = output; process.standardError = FileHandle.nullDevice; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1); XCTAssertEqual(try JSON.parse(output.fileHandleForReading.readDataToEndOfFile())["error"]["code"], .string("state_version"))
        let state = try StateStore(directory: directory); for table in tables { XCTAssertEqual(try state.rows("SELECT * FROM " + table + " ORDER BY rowid"), history[table]) }; try state.verifyAudit()
    }
    func testAllDayTerminationAndCopyFailBeforeIntentWhileHistoricalNoncesReplay() throws {
        let state = try state(), base = try fixture(), broker = Broker(state: state, backend: base, now: { self.initialNow })
        for index in base.events.indices {
            let start = try parseDate(String(base.events[index].fields.start.prefix(10)) + "T00:00:00Z")
            base.events[index].fields.start = iso(start); base.events[index].fields.end = iso(start.addingTimeInterval(86400))
            base.events[index].fields.allDay = true; base.events[index].fields.timeZone = "UTC"; base.events[index].occurrence = iso(start)
        }
        let events = views(broker)
        XCTAssertEqual(draft(broker, events[0]["id"])["error"]["code"], .string("unsupported_restore"))
        let selected = base.events[2], anchor = base.events[0], before = try broker.view(selected), anchorView = try broker.view(anchor)
        let resolved = try FutureCutoff(.object(["at": .string(selected.fields.start)]))
        let rule = try FutureTerminationPattern.copyRecurrence(selected: selected, anchor: anchor, now: initialNow)
        let future: JSON = .object(["provider_scope": .string("selected_occurrence_and_future"), "cutoff": resolved.json, "resolved_cutoff": .string(iso(resolved.start)), "boundary": .string(selected.fields.start), "reference": anchorView, "first_anchor": anchorView, "selection_window": resolved.window, "removes_entire_current_pattern": .bool(false), "copy_recurrence": rule.json])
        let deletion = try broker.terminationPreview(action: "delete", calendar: before["calendar"], before: before, after: .null, future: future)["preview"]
        XCTAssertEqual(commit(broker, deletion)["error"]["code"], .string("unsupported_restore"))
        XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "0"); XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "0")
        let source = deletion["envelope"], sourceNonce = source["nonce"].string!
        _ = try state.claim(nonce: sourceNonce, payload: source, now: initialNow)
        let applied: JSON = .object(["nonce": .string(sourceNonce), "state": .string("applied"), "action": .string("delete"), "deleted_boundary": before, "past_anchor": anchorView])
        try state.finish(nonce: sourceNonce, state: "applied", result: applied, event: "write_applied")
        XCTAssertEqual(commit(broker, deletion)["result"], applied)
        let history = call(broker, "list_changes")["result"]["changes"].array!
        XCTAssertEqual(history.first?["recovery_reason"], .string("all_day_copy_unsupported"))
        XCTAssertNotEqual(rollback(broker, .string(sourceNonce))["error"], .null)
        var fields = selected.fields; fields.recurrence = rule
        let restoration: JSON = .object(["details": broker.recoveryDetails(selected.details), "availability": .string(selected.availability), "past_anchor": anchorView])
        let rollback: JSON = .object(["selection_id": .string(UUID().uuidString), "source_change_ids": .array([.string(sourceNonce)]), "source_digest": .string(try broker.sourceDigest(state.recoveryRows())), "restoration": restoration, "limitations": .array(Broker.terminationLimitations.map(JSON.string))])
        let copy = try broker.terminationPreview(action: "create", calendar: before["calendar"], before: .null, after: fields.json, future: future, rollback: rollback)["preview"]
        XCTAssertEqual(commit(broker, copy, restore: true)["error"]["code"], .string("unsupported_restore"))
        XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "1")
        let copyNonce = copy["envelope"]["nonce"].string!
        _ = try state.claim(nonce: copyNonce, payload: copy["envelope"], now: initialNow)
        let unknown: JSON = .object(["nonce": .string(copyNonce), "state": .string("unknown"), "action": .string("create")])
        try state.finish(nonce: copyNonce, state: "unknown", result: unknown, event: "write_unknown")
        XCTAssertEqual(commit(broker, copy, restore: true)["result"], unknown)
        XCTAssertEqual(base.writeCount, 0); XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "1")
        XCTAssertEqual(try state.execution(sourceNonce)?.payload, source)
        try state.verifyAudit()
    }
}
