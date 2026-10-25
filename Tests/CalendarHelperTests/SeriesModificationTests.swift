import XCTest
import Foundation
import CryptoKit
import CSQLite
@testable import CalendarCore

private final class SeriesProbeBackend: CalendarBackend {
    let base: SyntheticBackend
    var missingAnchor = false, changeIdentity = false, corruptStructure = false, throwBeforeWrite = false
    init(_ base: SyntheticBackend) { self.base = base }
    func calendars() throws -> [CalendarRecord] { try base.calendars() }
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] { try base.query(start: start, end: end, calendarIDs: calendarIDs) }
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord { try base.get(nativeID: nativeID, calendarID: calendarID, occurrence: occurrence, knownStart: knownStart) }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? { try base.apply(action: action, calendarID: calendarID, existing: existing, fields: fields) }
    func applyRestoringAlarms(calendarID: String, existing: EventRecord, fields: EventFields, alarms: JSON) throws -> EventRecord? { try base.applyRestoringAlarms(calendarID: calendarID, existing: existing, fields: fields, alarms: alarms) }
    func restore(calendarID: String, fields: EventFields, details: JSON, availability: String) throws -> EventRecord { try base.restore(calendarID: calendarID, fields: fields, details: details, availability: availability) }
    func firstSeriesOccurrence(for selected: EventRecord) throws -> EventRecord {
        if missingAnchor { throw CoreError("event_missing", "Synthetic missing first anchor") }
        return try base.firstSeriesOccurrence(for: selected)
    }
    func applySeriesFields(anchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?) throws -> EventRecord {
        if throwBeforeWrite { throw CoreError("synthetic_unavailable", "Synthetic provider entry failure") }
        var saved = try base.applySeriesFields(anchor: anchor, fields: fields, changedFields: changedFields, restoredAlarms: restoredAlarms)
        if changeIdentity {
            for index in base.events.indices where base.events[index].nativeID == anchor.nativeID { base.events[index].nativeID = "new-direct-save-identity" }
            saved.nativeID = "new-direct-save-identity"
        }
        if corruptStructure {
            for index in base.events.indices where base.events[index].nativeID == saved.nativeID {
                var details = base.events[index].details.object!; details["recurrence_rules"] = .array([]); base.events[index].details = .object(details)
            }
        }
        return saved
    }
}

final class SeriesModificationTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() { for dir in directories { try? FileManager.default.removeItem(at: dir) }; super.tearDown() }
    private func store() throws -> StateStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-series-defaults-" + UUID().uuidString); directories.append(dir)
        let state = try StateStore(directory: dir); try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "a", count: 64)); return state
    }
    private func fixture() throws -> SyntheticBackend {
        let rule = try EventRecurrence(json: .object(["frequency": .string("weekly")])).rawRule
        return SyntheticBackend(events: [25, 32, 39, 46].enumerated().map { index, _ in
            let starts = ["2026-10-25T10:00:00.000Z", "2026-11-01T10:00:00.000Z", "2026-11-08T10:00:00.000Z", "2026-11-15T10:00:00.000Z"]
            let ends = ["2026-10-25T11:00:00.000Z", "2026-11-01T11:00:00.000Z", "2026-11-08T11:00:00.000Z", "2026-11-15T11:00:00.000Z"]
            return EventRecord(nativeID: index == 3 ? "separate-pattern" : "current-pattern", calendarNativeID: "synthetic-calendar", occurrence: starts[index], fields: EventFields(title: index == 2 ? "Detached override" : "Original default", start: starts[index], end: ends[index], timeZone: "Europe/London", allDay: false, notes: "Original notes"), recurring: true, detached: index == 2, details: .object(["alarms": .array([]), "recurrence_rules": .array([rule]), "url": .null, "structured_location": .null]))
        })
    }
    private func call(_ broker: Broker, _ op: String, _ args: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(op), "arguments": .object(args)])) }
    private func events(_ broker: Broker) -> [JSON] { call(broker, "query_events", ["start": .string("2026-10-01T00:00:00Z"), "end": .string("2026-12-01T00:00:00Z")])["result"]["events"].array! }
    private func draft(_ broker: Broker, id: JSON, fields: [String: JSON]) -> JSON { call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("series"), "event_id": id, "fields": .object(fields)]) }
    private func commit(_ broker: Broker, _ preview: JSON, rollback: Bool = false) -> JSON { call(broker, rollback ? "commit_series_rollback" : "commit_series_modify", ["preview": preview]) }
    private func rollback(_ broker: Broker, _ nonce: JSON) -> JSON { call(broker, "preflight_rollback", ["change_ids": .array([nonce])]) }
    private func sign(_ envelope: [String: JSON], _ state: StateStore) throws -> JSON {
        let body = JSON.object(envelope), key = SymmetricKey(data: Data(base64Encoded: try state.metadata("signing_key")!)!)
        return .object(["envelope": body, "authentication_tag": .string(Data(HMAC<SHA256>.authenticationCode(for: try body.data(), using: key)).base64EncodedString())])
    }

    func testExactCapabilityFloorFirstAnchorFieldPropagationAndOneIntentQuota() throws {
        let state = try store(), base = try fixture(), broker = Broker(state: state, backend: base), views = events(broker)
        XCTAssertEqual(call(broker, "series_modification_capabilities")["result"], Broker.seriesModificationCapabilities)
        XCTAssertEqual(call(broker, "recovery_capabilities")["result"]["storage_version"], .int(5))
        let response = draft(broker, id: views[1]["id"], fields: ["title": .string("New default"), "notes": .string("New notes")]), preview = response["result"]["preview"], envelope = preview["envelope"]
        XCTAssertEqual(envelope["version"], .int(4)); XCTAssertEqual(envelope["series"]["selected"], views[1]); XCTAssertEqual(envelope["before"], views[0])
        XCTAssertEqual(envelope["series"]["changed_fields"], .array([.string("notes"), .string("title")]))
        XCTAssertEqual(envelope["recovery"], Broker.seriesRecovery); XCTAssertEqual(envelope["after"].object?.count, 7)
        let alerts = draft(broker, id: views[1]["id"], fields: ["alerts": .array([.object(["at": .string("2026-10-25T11:00:00+01:00")]), .object(["relative_minutes": .int(-5)])])])["result"]["preview"]["envelope"]["after"]["alerts"].array!
        XCTAssertTrue(alerts.contains(.object(["at": .string("2026-10-25T10:00:00.000Z")])))
        XCTAssertNotEqual(call(broker, "commit_modify", ["preview": preview])["error"], .null)
        XCTAssertNotEqual(call(broker, "commit_rollback", ["preview": preview])["error"], .null)
        XCTAssertEqual(base.writeCount, 0)
        let original = base.events, result = commit(broker, preview)
        XCTAssertEqual(result["result"]["state"], .string("applied")); XCTAssertEqual(result["result"]["event"]["id"], views[0]["id"])
        XCTAssertEqual(base.events[0].fields.title, "New default"); XCTAssertEqual(base.events[1].fields.title, "New default")
        XCTAssertEqual(base.events[2], original[2]); XCTAssertEqual(base.events[3], original[3]); XCTAssertEqual(base.writeCount, 1)
        XCTAssertEqual(commit(broker, preview), result); XCTAssertEqual(base.writeCount, 1)
        let marker = try JSON.parse(Data(state.rows("SELECT payload FROM executions")[0][0].utf8))
        XCTAssertEqual(marker["calendar_id"], views[0]["calendar"]["id"]); XCTAssertEqual(marker["scope"], .string("series")); XCTAssertEqual(marker["series_anchor_id"], views[0]["id"])
        XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "1")
        XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "1"); try state.verifyAudit()
    }

    func testInverseRestoresOnlyMaskedDefaultsAndRawAlarmsThroughDedicatedTool() throws {
        let state = try store(), base = try fixture()
        var details = base.events[0].details.object!; details["alarms"] = .array([.object(["absolute_date": .null, "relative_offset": .string("-300.0"), "proximity": .int(0), "structured_location": .null, "type": .int(1), "email_address": .null, "sound_name": .string("Synthetic sound")])])
        base.events[0].details = .object(details); base.events[1].details = .object(details)
        let broker = Broker(state: state, backend: base), view = events(broker)[1], original = base.events[0]
        let preview = draft(broker, id: view["id"], fields: ["title": .string("Changed default"), "alerts": .array([.object(["relative_minutes": .int(-20)])])])["result"]["preview"]
        let result = commit(broker, preview), plan = rollback(broker, result["result"]["nonce"]), step = plan["result"]["steps"].array![0], inverse = step["preview"]
        XCTAssertEqual(step["commit_tool"], .string("commit_series_rollback")); XCTAssertEqual(inverse["envelope"]["version"], .int(4))
        XCTAssertEqual(inverse["envelope"]["series"]["selected"], inverse["envelope"]["before"])
        XCTAssertEqual(inverse["envelope"]["rollback"]["alarm_restoration"], original.details["alarms"])
        XCTAssertEqual(inverse["envelope"]["after"].object?.count, 7)
        XCTAssertNotEqual(call(broker, "commit_rollback", ["preview": inverse])["error"], .null)
        XCTAssertNotEqual(commit(broker, inverse)["error"], .null)
        let restored = commit(broker, inverse, rollback: true)
        XCTAssertEqual(restored["result"]["state"], .string("applied")); XCTAssertEqual(base.events[0], original)
        XCTAssertEqual(commit(broker, inverse, rollback: true), restored); XCTAssertEqual(base.writeCount, 2)
        XCTAssertNotEqual(rollback(broker, result["result"]["nonce"])["error"], .null)
        XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "2")
    }

    func testLegacyLongUnmaskedTextAndInverseRetainedTextArePreserved() throws {
        let state = try store(), base = try fixture(), original = String(repeating: "Legacy notes ", count: 1200)
        for index in [0, 1] { base.events[index].fields.notes = original }
        let broker = Broker(state: state, backend: base), id = events(broker)[1]["id"]
        let first = commit(broker, draft(broker, id: id, fields: ["title": .string("Changed title")])["result"]["preview"])
        XCTAssertEqual(first["result"]["state"], .string("applied")); XCTAssertEqual(base.events[0].fields.notes, original)
        let second = commit(broker, draft(broker, id: id, fields: ["notes": .string("Short notes")])["result"]["preview"])
        let inverse = rollback(broker, second["result"]["nonce"])["result"]["steps"].array![0]["preview"]
        XCTAssertEqual(inverse["envelope"]["after"]["notes"], .string(original))
        XCTAssertEqual(commit(broker, inverse, rollback: true)["result"]["state"], .string("applied")); XCTAssertEqual(base.events[0].fields.notes, original)
    }

    func testStructuralAndDetachedSelectionsFailBeforeIntent() throws {
        let state = try store(), base = try fixture(), probe = SeriesProbeBackend(base), broker = Broker(state: state, backend: probe), views = events(broker)
        for patch: [String: JSON] in [["start": .string("2026-10-26T10:00:00Z")], ["end": .string("2026-10-26T11:00:00Z")], ["all_day": .bool(true)], ["time_zone": .string("UTC")], ["recurrence": .null], [:], ["title": .string("  ")]] { XCTAssertNotEqual(draft(broker, id: views[1]["id"], fields: patch)["error"], .null) }
        XCTAssertEqual(draft(broker, id: views[2]["id"], fields: ["title": .string("Disallowed")])["error"]["code"], .string("unsupported_scope"))
        XCTAssertEqual(draft(broker, id: views[1]["id"], fields: ["title": .string("Original default")])["error"]["code"], .string("no_change"))
        probe.missingAnchor = true
        XCTAssertEqual(draft(broker, id: views[1]["id"], fields: ["title": .string("Missing anchor")])["error"]["code"], .string("event_missing"))
        XCTAssertEqual(base.writeCount, 0); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
    }

    func testExistingEligibilityGuardsAndStructuredLocationApplyToFirstAnchor() throws {
        for scenario in ["meeting", "organizer", "external_alarm", "cancelled", "nil_all_day", "read_only", "structured_location"] {
            let state = try store(), base = try fixture(), broker = Broker(state: state, backend: base), id = events(broker)[1]["id"]
            var patch: [String: JSON] = ["title": .string("Blocked default")]
            switch scenario {
            case "meeting": base.events[0].hasAttendees = true
            case "organizer": base.events[0].hasOrganizer = true
            case "external_alarm": var details = base.events[0].details.object!; details["unsupported_external_alarm"] = .bool(true); base.events[0].details = .object(details)
            case "cancelled": base.events[0].status = "cancelled"
            case "nil_all_day": base.events[0].fields.allDay = true; base.events[0].fields.timeZone = nil
            case "read_only": base.calendarRecords = [CalendarRecord(nativeID: "synthetic-calendar", title: "Synthetic Calendar", source: "Synthetic", writable: false)]
            default: var details = base.events[0].details.object!; details["structured_location"] = .object(["title": .string("Fixture place"), "radius": .string("0.0")]); base.events[0].details = .object(details); patch = ["location": .string("Replacement")]
            }
            XCTAssertNotEqual(draft(broker, id: id, fields: patch)["error"], .null, scenario)
            XCTAssertEqual(base.writeCount, 0); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
        }
    }

    func testSignedSemanticTamperMaskDisclosureAndSelectedStalenessRejectBeforeIntent() throws {
        let state = try store(), base = try fixture(), broker = Broker(state: state, backend: base), id = events(broker)[1]["id"]
        let preview = draft(broker, id: id, fields: ["title": .string("Valid title")])["result"]["preview"]
        for mutation in 0..<6 {
            var body = preview["envelope"].object!
            if mutation == 0 { var series = body["series"]!.object!; series["changed_fields"] = .array([.string("title"), .string("title")]); body["series"] = .object(series) }
            if mutation == 1 { var after = body["after"]!.object!; after["notes"] = .string("Unmasked replacement"); body["after"] = .object(after) }
            if mutation == 2 { var after = body["after"]!.object!; after["start"] = .string("2026-10-26T10:00:00Z"); body["after"] = .object(after) }
            if mutation == 3 { body["recovery"] = .object(["mode": .string("series_default_fields"), "limitations": .array([])]) }
            if mutation == 4 { var after = body["after"]!.object!; after["alerts"] = .array([]); body["after"] = .object(after) }
            if mutation == 5 { body["after"] = body["before"]!["fields"] }
            XCTAssertNotEqual(commit(broker, try sign(body, state))["error"], .null)
        }
        base.events[1].fields.notes = "Changed selected occurrence"
        XCTAssertEqual(commit(broker, preview)["error"]["code"], .string("stale_event"))
        XCTAssertEqual(base.writeCount, 0); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
    }

    func testProviderFailureAndVerificationMismatchRemainUnknownWithoutRetry() throws {
        for failBefore in [false, true] {
            let state = try store(), base = try fixture(), probe = SeriesProbeBackend(base), broker = Broker(state: state, backend: probe), id = events(broker)[1]["id"]
            let preview = draft(broker, id: id, fields: ["title": .string("Uncertain default")])["result"]["preview"]
            probe.throwBeforeWrite = failBefore; probe.corruptStructure = !failBefore
            let result = commit(broker, preview)
            XCTAssertEqual(result["result"]["state"], .string("unknown")); XCTAssertEqual(commit(broker, preview), result)
            XCTAssertEqual(base.writeCount, failBefore ? 0 : 1); XCTAssertTrue(try state.hasUnresolved())
            XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "1")
            XCTAssertEqual(commit(broker, draft(broker, id: id, fields: ["notes": .string("Another")])["result"]["preview"])["error"]["code"], .string("unresolved_write"))
        }
    }

    func testDirectSavedIdentityRebindsAnchorWithoutHijackingLaterOccurrenceID() throws {
        let state = try store(), base = try fixture(), probe = SeriesProbeBackend(base), broker = Broker(state: state, backend: probe), views = events(broker)
        let preview = draft(broker, id: views[1]["id"], fields: ["title": .string("Reidentified default")])["result"]["preview"]
        probe.changeIdentity = true
        let result = commit(broker, preview)
        XCTAssertEqual(result["result"]["state"], .string("applied")); XCTAssertEqual(result["result"]["event"]["id"], views[0]["id"])
        XCTAssertEqual(try state.resolve(views[0]["id"].string!, kind: "event").nativeID, "new-direct-save-identity")
        let later = try state.resolve(views[1]["id"].string!, kind: "event")
        XCTAssertEqual(later.nativeID, "current-pattern"); XCTAssertEqual(later.occurrence, views[1]["occurrence"].string)
        XCTAssertEqual(call(broker, "get_event", ["event_id": views[1]["id"]])["error"]["code"], .string("event_missing"))
        XCTAssertEqual(call(broker, "get_event", ["event_id": views[0]["id"]])["result"]["event"], result["result"]["event"])
    }

    func testIndependentLaterGroupAllowsInverseWhileSameGroupCrossingSurvivesDetailExpiry() throws {
        let state = try store(), base = try fixture(), broker = Broker(state: state, backend: base), views = events(broker)
        let ordinary = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("this"), "event_id": views[1]["id"], "fields": .object(["notes": .string("Occurrence notes")])])["result"]["preview"]
        let ordinaryResult = call(broker, "commit_modify", ["preview": ordinary])
        let result = commit(broker, draft(broker, id: views[0]["id"], fields: ["title": .string("Series boundary")])["result"]["preview"])
        XCTAssertEqual(rollback(broker, ordinaryResult["result"]["nonce"])["error"]["code"], .string("rollback_series_boundary"))
        let plan = rollback(broker, result["result"]["nonce"])
        XCTAssertEqual(plan["result"]["step_count"], .int(1))
        let inverse = plan["result"]["steps"].array![0]["preview"]
        let later = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("this"), "event_id": views[3]["id"], "fields": .object(["notes": .string("Another pattern in same calendar")])])["result"]["preview"]
        XCTAssertEqual(call(broker, "commit_modify", ["preview": later])["result"]["state"], .string("applied"))
        XCTAssertEqual(rollback(broker, result["result"]["nonce"])["result"]["step_count"], .int(1))
        XCTAssertEqual(commit(broker, inverse, rollback: true)["result"]["state"], .string("applied"))
        let nonce = result["result"]["nonce"].string!
        // Expired series evidence leaves its structural crossing marker intact.
        try state.execute("DELETE FROM execution_keys WHERE nonce=?", [nonce]); try state.execute("UPDATE execution_details SET expired=1 WHERE nonce=?", [nonce])
        XCTAssertEqual(rollback(broker, ordinaryResult["result"]["nonce"])["error"]["code"], .string("rollback_series_boundary"))
    }

    func testMixedAndMultipleSeriesRecoverySelectionsAreRejected() throws {
        let state = try store(), base = try fixture(), broker = Broker(state: state, backend: base), views = events(broker)
        let first = commit(broker, draft(broker, id: views[0]["id"], fields: ["title": .string("First series")])["result"]["preview"])
        let second = commit(broker, draft(broker, id: views[3]["id"], fields: ["title": .string("Second series")])["result"]["preview"])
        XCTAssertEqual(call(broker, "preflight_rollback", ["change_ids": .array([first["result"]["nonce"], second["result"]["nonce"]])])["error"]["code"], .string("invalid_selection"))
    }

    func testUnknownIndependentSeriesAllowsSameCalendarSeriesInverseAndKeepsUnknownReplay() throws {
        let state = try store(), base = try fixture(), probe = SeriesProbeBackend(base), broker = Broker(state: state, backend: probe), views = events(broker)
        let source = commit(broker, draft(broker, id: views[1]["id"], fields: ["title": .string("Recover this pattern")])["result"]["preview"])
        let unknownPreview = draft(broker, id: views[3]["id"], fields: ["title": .string("Unknown separate pattern")])["result"]["preview"]
        probe.throwBeforeWrite = true
        let unknown = commit(broker, unknownPreview)
        XCTAssertEqual(unknown["result"]["state"], .string("unknown"))
        probe.throwBeforeWrite = false
        let plan = rollback(broker, source["result"]["nonce"])
        XCTAssertEqual(plan["result"]["step_count"], .int(1))
        let inverse = try XCTUnwrap(plan["result"]["steps"].array?.first?["preview"])
        XCTAssertEqual(commit(broker, inverse, rollback: true)["result"]["state"], .string("applied"))
        XCTAssertEqual(commit(broker, unknownPreview), unknown)
        XCTAssertTrue(try state.hasUnresolved()); XCTAssertEqual(base.writeCount, 2)
        XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "3")
    }

    func testUnknownOccurrenceAllowsIndependentSignedSeriesButBlocksSameGroupWithoutChangingUnknownEvidence() throws {
        let state = try store(), base = try fixture(), broker = Broker(state: state, backend: base), views = events(broker)
        let ordinary = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("this"), "event_id": views[1]["id"], "fields": .object(["notes": .string("Unknown occurrence notes")])])["result"]["preview"]
        base.throwAfterWrite = true
        let unknown = call(broker, "commit_modify", ["preview": ordinary]), nonce = try XCTUnwrap(unknown["result"]["nonce"].string)
        XCTAssertEqual(unknown["result"]["state"], .string("unknown")); base.throwAfterWrite = false
        let journal = try state.rows("SELECT * FROM executions WHERE nonce=?", [nonce])
        let detail = try state.rows("SELECT * FROM execution_details WHERE nonce=?", [nonce])
        let key = try state.rows("SELECT * FROM execution_keys WHERE nonce=?", [nonce])
        let quota = try state.rows("SELECT * FROM write_safety_claims WHERE nonce=?", [nonce])
        let same = draft(broker, id: views[0]["id"], fields: ["title": .string("Blocked same group")])["result"]["preview"]
        XCTAssertEqual(commit(broker, same)["error"]["code"], .string("unresolved_write"))
        let independent = draft(broker, id: views[3]["id"], fields: ["title": .string("Independent pattern succeeds")])["result"]["preview"]
        XCTAssertEqual(commit(broker, independent)["result"]["state"], .string("applied"))
        XCTAssertEqual(call(broker, "commit_modify", ["preview": ordinary]), unknown)
        XCTAssertEqual(try state.rows("SELECT * FROM executions WHERE nonce=?", [nonce]), journal)
        XCTAssertEqual(try state.rows("SELECT * FROM execution_details WHERE nonce=?", [nonce]), detail)
        XCTAssertEqual(try state.rows("SELECT * FROM execution_keys WHERE nonce=?", [nonce]), key)
        XCTAssertEqual(try state.rows("SELECT * FROM write_safety_claims WHERE nonce=?", [nonce]), quota)
        XCTAssertEqual(base.writeCount, 2); XCTAssertTrue(try state.hasUnresolved())
    }

    func testUnknownIndependentSeriesDoesNotBlockOccurrenceInverseInSameCalendar() throws {
        let state = try store(), base = try fixture(), probe = SeriesProbeBackend(base), broker = Broker(state: state, backend: probe), views = events(broker)
        let ordinary = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("this"), "event_id": views[1]["id"], "fields": .object(["notes": .string("Recover occurrence notes")])])["result"]["preview"]
        let source = call(broker, "commit_modify", ["preview": ordinary])
        probe.throwBeforeWrite = true
        let unknown = commit(broker, draft(broker, id: views[3]["id"], fields: ["title": .string("Independent unknown")])["result"]["preview"])
        XCTAssertEqual(unknown["result"]["state"], .string("unknown")); probe.throwBeforeWrite = false
        let plan = rollback(broker, source["result"]["nonce"])
        XCTAssertEqual(plan["result"]["step_count"], .int(1))
        let inverse = try XCTUnwrap(plan["result"]["steps"].array?.first?["preview"])
        XCTAssertEqual(call(broker, "commit_rollback", ["preview": inverse])["result"]["state"], .string("applied"))
        XCTAssertTrue(try state.hasUnresolved()); XCTAssertEqual(base.writeCount, 2)
    }

    func testSeriesQuotaRecheckAndLocalReviewedInverseUseExistingNativePolicies() throws {
        let state = try store(), base = try fixture(), broker = Broker(state: state, backend: base), id = events(broker)[1]["id"]
        let policy: JSON = .object(["version": .int(1), "delete_hour": .int(1), "delete_day": .int(1), "destructive_hour": .int(1), "destructive_day": .int(1)])
        let path = state.directory.appendingPathComponent("write-safety.json")
        try policy.data().write(to: path); XCTAssertEqual(chmod(path.path, 0o600), 0)
        let preview = draft(broker, id: id, fields: ["title": .string("One budgeted series")])["result"]["preview"]
        let result = commit(broker, preview), inverse = rollback(broker, result["result"]["nonce"])["result"]["steps"].array![0]["preview"]
        XCTAssertEqual(broker.commitReviewedRollback(inverse)["error"]["code"], .string("write_safety_limit"))
        XCTAssertEqual(base.writeCount, 1); XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "1")
        let counts = try state.commitObservationStatus()["observations"].array!
        XCTAssertTrue(counts.contains { $0["reason"] == .string("write_safety_limit") && $0["origin"] == .string("local_native_ui") && $0["count"] == .int(1) })
        let larger: JSON = .object(["version": .int(1), "delete_hour": .int(1), "delete_day": .int(1), "destructive_hour": .int(2), "destructive_day": .int(2)])
        try larger.data().write(to: path)
        XCTAssertEqual(broker.commitReviewedRollback(inverse)["result"]["state"], .string("applied"))
        let intent = try state.auditRecords().last { $0["event"] == .string("write_intent") }
        XCTAssertEqual(intent?["approval_source"], .string("local_native_ui")); XCTAssertEqual(intent?["approval_evidence"], .string("native_control_activated"))
        XCTAssertEqual(base.writeCount, 2); XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "2")
    }

    func testUnrelatedCalendarAllowsInverseWhileUnprovableLegacyRelationBlocks() throws {
        let state = try store(), base = try fixture(), broker = Broker(state: state, backend: base), id = events(broker)[1]["id"]
        let result = commit(broker, draft(broker, id: id, fields: ["title": .string("Retained series")])["result"]["preview"])
        base.calendarRecords.append(CalendarRecord(nativeID: "unrelated-calendar", title: "Other synthetic calendar", source: "Synthetic"))
        let other = call(broker, "list_calendars")["result"]["calendars"].array!.first { $0["title"] == .string("Other synthetic calendar") }!["id"]
        let preview = call(broker, "preflight_change", ["action": .string("create"), "scope": .string("this"), "calendar_id": other, "fields": .object(["title": .string("Unrelated synthetic"), "start": .string("2026-10-25T10:00:00Z"), "end": .string("2026-10-25T11:00:00Z")])])["result"]["preview"]
        XCTAssertEqual(call(broker, "commit_create", ["preview": preview])["result"]["state"], .string("applied"))
        XCTAssertEqual(rollback(broker, result["result"]["nonce"])["result"]["step_count"], .int(1))
        let nonce = UUID().uuidString
        _ = try state.claim(nonce: nonce, payload: .object(["action": .string("create")]), now: Date())
        try state.finish(nonce: nonce, state: "applied", result: .object(["state": .string("applied")]), event: "synthetic_outcome")
        XCTAssertEqual(rollback(broker, result["result"]["nonce"])["error"]["code"], .string("rollback_series_boundary"))
    }

    func testInverseExpiryCannotOutliveRetainedSource() throws {
        let state = try store(), base = try fixture()
        let path = state.directory.appendingPathComponent("recovery-policy.json")
        try JSON.object(["version": .int(1), "retention_days": .int(1)]).data().write(to: path); XCTAssertEqual(chmod(path.path, 0o600), 0)
        var current = Date()
        let broker = Broker(state: state, backend: base, now: { current }), id = events(broker)[1]["id"]
        let result = commit(broker, draft(broker, id: id, fields: ["notes": .string("One-day source")])["result"]["preview"])
        current.addTimeInterval(86400 - 100)
        let inverse = rollback(broker, result["result"]["nonce"])["result"]["steps"].array![0]["preview"]
        let expiry = try parseDate(inverse["envelope"]["expires_at"].string!)
        XCTAssertLessThanOrEqual(expiry.timeIntervalSince(current), 100.001)
        current.addTimeInterval(101)
        XCTAssertEqual(commit(broker, inverse, rollback: true)["error"]["code"], .string("preview_expired"))
        XCTAssertEqual(base.writeCount, 1)
    }

    func testFloor3UnexpectedPlaintextFailsWithoutRewritingAnyAuthoritativeRows() throws {
        let dir: URL, snapshot: [String: [[String]]]
        let tables = ["executions", "execution_details", "execution_keys", "write_safety_claims", "audit", "legacy_audit_manifest", "legacy_audit_details", "metadata"]
        do {
            let state = try store(); dir = state.directory
            let nonce = UUID().uuidString
            _ = try state.claim(nonce: nonce, payload: .object(["action": .string("create")]), now: Date())
            try state.finish(nonce: nonce, state: "applied", result: .object(["state": .string("applied")]), event: "synthetic_outcome")
            try state.execute("DROP TRIGGER payload_immutable")
            try state.execute("UPDATE executions SET payload='{" + "\"action\":\"create\"}'")
            snapshot = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try state.rows("SELECT * FROM " + $0 + " ORDER BY rowid")) })
        }
        XCTAssertThrowsError(try StateStore(directory: dir)) { XCTAssertEqual(($0 as? CoreError)?.code, "state_corrupt") }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dir.appendingPathComponent("state.sqlite3").path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        for table in tables {
            var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT * FROM " + table + " ORDER BY rowid", -1, &statement, nil), SQLITE_OK)
            var rows: [[String]] = []
            while sqlite3_step(statement) == SQLITE_ROW { rows.append((0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_text(statement, $0)) }) }
            sqlite3_finalize(statement); XCTAssertEqual(rows, snapshot[table])
        }
    }

    func testV3WriterFloorPreservesEncodingHistoryAndFrozenLegacyRefusesStartup() throws {
        let dir: URL, snapshots: [String: [[String]]]
        let tables = ["executions", "execution_details", "execution_keys", "write_safety_claims", "audit", "legacy_audit_manifest", "legacy_audit_details", "commit_observations", "commit_observation_clock"]
        do {
            let state = try store(); dir = state.directory
            let base = try fixture(), broker = Broker(state: state, backend: base), id = events(broker)[1]["id"]
            let result = commit(broker, draft(broker, id: id, fields: ["title": .string("Persisted series")])["result"]["preview"])
            XCTAssertEqual(result["result"]["state"], .string("applied")); XCTAssertEqual(commit(broker, draft(broker, id: id, fields: ["notes": .string("Retained notes")])["result"]["preview"])["result"]["state"], .string("applied"))
            snapshots = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try state.rows("SELECT * FROM " + $0 + " ORDER BY rowid")) })
            XCTAssertEqual(try state.metadata("recovery_storage_version"), "5")
            XCTAssertTrue(try state.rows("SELECT payload FROM executions").allSatisfy { (try? JSON.parse(Data($0[0].utf8))["storage_version"]) == .int(2) })
        }
        let frozen = "/private/tmp/calendar-recurrence-validated-raw/CalendarHelper"
        guard FileManager.default.isExecutableFile(atPath: frozen) else { throw XCTSkip("Frozen legacy helper unavailable for compatibility fence test") }
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: frozen)
        process.arguments = ["--migrate-recovery", "--state-dir", dir.path]; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertEqual(try JSON.parse(output.fileHandleForReading.readDataToEndOfFile())["error"]["code"], .string("state_version"))
        let reopened = try StateStore(directory: dir)
        for table in tables { XCTAssertEqual(try reopened.rows("SELECT * FROM " + table + " ORDER BY rowid"), snapshots[table]) }
        XCTAssertEqual(try reopened.metadata("recovery_storage_version"), "5"); try reopened.verifyAudit()
    }
}
