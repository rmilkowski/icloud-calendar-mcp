import XCTest
import Foundation
import CryptoKit
@testable import CalendarCore

private final class RecurrenceVerificationBackend: CalendarBackend {
    let base = SyntheticBackend()
    var corruption: String?
    func calendars() throws -> [CalendarRecord] { try base.calendars() }
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] { try base.query(start: start, end: end, calendarIDs: calendarIDs) }
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord { try base.get(nativeID: nativeID, calendarID: calendarID, occurrence: occurrence, knownStart: knownStart) }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? {
        let result = try base.apply(action: action, calendarID: calendarID, existing: existing, fields: fields)
        if action == "create", result != nil, let corruption {
            if corruption == "drop" { base.events[0].recurring = false; base.events[0].details = .object(["alarms": base.events[0].details["alarms"]]) }
            else if corruption == "detach" { base.events[0].detached = true }
            else {
                var details = base.events[0].details.object!, rules = details["recurrence_rules"]!.array!, rule = rules[0].object!
                if corruption == "interval" { rule["interval"] = .int(17) }
                if corruption == "selector" { rule["months_of_year"] = .array([.int(3)]) }
                rules[0] = .object(rule); details["recurrence_rules"] = .array(rules); base.events[0].details = .object(details)
            }
        }
        return result // Intentionally returns the uncorrupted provenance; verification must fetch.
    }
}

final class RecurrenceTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at: directory) }; super.tearDown() }
    private func state() throws -> StateStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-recurrence-test-" + UUID().uuidString); directories.append(directory)
        let state = try StateStore(directory: directory); try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "a", count: 64)); return state
    }
    private func call(_ broker: Broker, _ op: String, _ args: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(op), "arguments": .object(args)])) }
    private func rule(_ frequency: String = "weekly", interval: Int = 1, end: JSON = .null, days: [Int]? = nil) -> JSON {
        var value: [String: JSON] = ["frequency": .string(frequency), "interval": .int(interval), "end": end]
        if let days { value["days_of_week"] = .array(days.map(JSON.int)) }; return .object(value)
    }
    private func create(_ broker: Broker, recurrence: JSON? = nil, scope: String? = nil, extra: [String: JSON] = [:]) -> JSON {
        var fields: [String: JSON] = ["title": .string("Recurrence fixture"), "start": .string("2026-10-25T10:00:00Z"), "end": .string("2026-10-25T11:00:00Z")]
        if let recurrence { fields["recurrence"] = recurrence }; fields.merge(extra) { _, new in new }
        return call(broker, "preflight_change", ["action": .string("create"), "scope": .string(scope ?? (recurrence == nil ? "this" : "series")), "calendar_id": call(broker, "list_calendars")["result"]["calendars"].array![0]["id"], "fields": .object(fields)])["result"]["preview"]
    }
    private func commit(_ broker: Broker, _ preview: JSON, action: String = "create") -> JSON { call(broker, "commit_" + action, ["preview": preview]) }
    private func draft(_ broker: Broker, id: JSON, action: String, fields: JSON? = nil, scope: String = "this") -> JSON {
        var args: [String: JSON] = ["action": .string(action), "scope": .string(scope), "event_id": id]
        if let fields { args["fields"] = fields }; return call(broker, "preflight_change", args)
    }
    private func sign(_ envelope: JSON, state: StateStore) throws -> JSON {
        let key = SymmetricKey(data: Data(base64Encoded: try state.metadata("signing_key")!)!)
        return .object(["envelope": envelope, "authentication_tag": .string(Data(HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: key)).base64EncodedString())])
    }

    func testCanonicalDefaultsValidationAndBoundaries() throws {
        XCTAssertEqual(try EventRecurrence(json: .object(["frequency": .string("daily")])).json, rule("daily"))
        XCTAssertEqual(try EventRecurrence(json: rule(days: [7, 1, 3])).json, rule(days: [1, 3, 7]))
        XCTAssertEqual(try EventRecurrence(json: rule(end: .object(["until": .string("2026-10-25T11:00:00+01:00")]))).until, "2026-10-25T10:00:00.000Z")
        for invalid: JSON in [.null, .object([:]), rule("hourly"), rule(interval: 0), rule(interval: 1000), rule(days: []), rule(days: [1, 1]), rule(days: [0]), rule("monthly", days: [1]), rule(end: .object([:])), rule(end: .object(["count": .int(0)])), rule(end: .object(["count": .int(1001)])), rule(end: .object(["count": .bool(true)])), rule(end: .object(["until": .string("2026-10-25T10:00:00")])), rule(end: .object(["count": .int(1), "until": .string("2026-10-25T10:00:00Z")])), .object(["frequency": .string("daily"), "interval": .bool(true)]), .object(["frequency": .string("weekly"), "days_of_week": .array([.bool(true)])]), .object(["frequency": .string("daily"), "rrule": .string("FREQ=DAILY")])] {
            XCTAssertThrowsError(try EventRecurrence(json: invalid), "\(invalid)")
        }
        for frequency in ["daily", "weekly", "monthly", "yearly"] {
            let value = try EventRecurrence(json: rule(frequency, interval: 999, end: .object(["count": .int(1000)])))
            XCTAssertTrue(value.matches(raw: .array([value.rawRule])))
        }
        let fields: JSON = .object(["title": .string("Fixture"), "start": .string("2026-10-25T10:00:00Z"), "end": .string("2026-10-25T11:00:00Z"), "recurrence": rule(days: [2])])
        XCTAssertThrowsError(try EventFields.merged(fields, with: nil)) // Sunday DTSTART is not Monday.
        var value = fields.object!; value["recurrence"] = rule(end: .object(["until": .string("2026-10-24T10:00:00Z")]))
        XCTAssertThrowsError(try EventFields.merged(.object(value), with: nil))
        value["recurrence"] = rule(); value["time_zone"] = .null
        XCTAssertThrowsError(try EventFields.merged(.object(value), with: nil))
    }

    func testCapabilityExactCreateCanonicalReadbackAndReplay() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
        XCTAssertEqual(call(broker, "recurrence_capabilities")["result"], .object(["version": .int(1), "recurrence": .bool(true), "preview_version": .int(3), "create_series": .bool(true), "modify_occurrence": .bool(true), "delete_occurrence": .bool(true), "future_scope": .bool(false), "series_modify_delete": .bool(false), "delete_recovery": .string("standalone_copy"), "max_count": .int(1000)]))
        XCTAssertEqual(call(broker, "recurrence_capabilities", ["access": .bool(true)])["error"]["code"], .string("invalid_arguments"))
        let preview = create(broker, recurrence: .object(["frequency": .string("weekly"), "days_of_week": .array([.int(7), .int(1)])]))
        XCTAssertEqual(preview["envelope"]["version"], .int(3)); XCTAssertEqual(preview["envelope"]["scope"], .string("series"))
        XCTAssertEqual(preview["envelope"]["after"]["recurrence"], rule(days: [1, 7]))
        XCTAssertEqual(preview["envelope"]["recovery"], .object(["mode": .string("not_applicable"), "limitations": .array([])]))
        let result = commit(broker, preview)
        XCTAssertEqual(result["result"]["state"], .string("applied")); XCTAssertEqual(commit(broker, preview), result); XCTAssertEqual(backend.writeCount, 1)
        XCTAssertEqual(result["result"]["event"]["recurring"], .bool(true)); XCTAssertEqual(result["result"]["event"]["occurrence"], .string("2026-10-25T10:00:00.000Z"))
        XCTAssertEqual(result["result"]["event"]["fields"].object?.count, 7)
        XCTAssertEqual(call(broker, "get_event", ["event_id": result["result"]["event"]["id"]])["result"]["event"], result["result"]["event"])
        XCTAssertEqual(try state.execution(preview["envelope"]["nonce"].string!)?.payload, preview["envelope"]); try state.verifyAudit()
    }

    func testCreateFrequenciesCountUntilOpenEndAndDSTAllDay() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
        for frequency in ["daily", "weekly", "monthly", "yearly"] {
            for end: JSON in [.null, .object(["count": .int(1)]), .object(["count": .int(1000)]), .object(["until": .string("2027-10-25T10:00:00Z")])] {
                XCTAssertEqual(commit(broker, create(broker, recurrence: rule(frequency, interval: 2, end: end)))["result"]["state"], .string("applied"))
            }
        }
        let preview = create(broker, recurrence: rule("daily"), extra: ["start": .string("2026-10-25T00:00:00+01:00"), "end": .string("2026-10-26T00:00:00Z"), "all_day": .bool(true)])
        XCTAssertEqual(commit(broker, preview)["result"]["state"], .string("applied")); XCTAssertEqual(backend.events.last?.fields.allDay, true)
    }

    func testScopeTamperCanonicalAndLegacyRecurrenceRejectBeforeIntent() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
        XCTAssertEqual(create(broker, recurrence: rule(), scope: "this"), .null)
        XCTAssertEqual(create(broker, scope: "series"), .null)
        XCTAssertEqual(create(broker, recurrence: .null), .null)
        let preview = create(broker, recurrence: rule())
        var changed = preview.object!, envelope = preview["envelope"].object!
        envelope["scope"] = .string("this"); changed["envelope"] = .object(envelope)
        XCTAssertEqual(commit(broker, .object(changed))["error"]["code"], .string("invalid_preview"))
        for version in [1, 2] {
            var legacy = preview["envelope"].object!; legacy["version"] = .int(version); legacy.removeValue(forKey: "recovery"); legacy["scope"] = .string("this")
            XCTAssertEqual(commit(broker, try sign(.object(legacy), state: state))["error"]["code"], .string("invalid_preview"))
        }
        envelope = preview["envelope"].object!; envelope["recovery"] = .object(["mode": .string("not_applicable"), "limitations": .array([.string("Caller changed warning")])])
        XCTAssertEqual(commit(broker, try sign(.object(envelope), state: state))["error"]["code"], .string("invalid_preview"))
        envelope = preview["envelope"].object!; var fields = envelope["after"]!.object!; fields["recurrence"] = .object(["frequency": .string("weekly")]); envelope["after"] = .object(fields)
        XCTAssertEqual(commit(broker, try sign(.object(envelope), state: state))["error"]["code"], .string("invalid_preview"))
        XCTAssertEqual(backend.writeCount, 0); XCTAssertEqual(try state.rows("SELECT nonce FROM executions").count, 0)
    }

    func testIndividualModificationPreservesOtherOccurrenceAndRejectsWidenedScope() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
        let created = commit(broker, create(broker, recurrence: rule(end: .object(["count": .int(2)])))), id = created["result"]["event"]["id"]
        var second = backend.events[0]; second.occurrence = "2026-11-01T10:00:00.000Z"; second.fields.start = "2026-11-01T10:00:00.000Z"; second.fields.end = "2026-11-01T11:00:00.000Z"; backend.events.append(second)
        let changed = draft(broker, id: id, action: "modify", fields: .object(["title": .string("One occurrence")]))
        XCTAssertEqual(changed["result"]["preview"]["envelope"]["recovery"]["limitations"], .array([.string(Broker.occurrenceRecoveryLimitation)]))
        XCTAssertEqual(commit(broker, changed["result"]["preview"], action: "modify")["result"]["state"], .string("applied")); XCTAssertEqual(backend.events[1], second)
        for scope in ["future", "series"] { for action in ["modify", "delete"] { XCTAssertEqual(draft(broker, id: id, action: action, fields: action == "modify" ? .object(["title": .string("Widen")]) : nil, scope: scope)["error"]["code"], .string("unsupported_scope")) } }
        for recurrence: JSON in [rule(), .null] { XCTAssertEqual(draft(broker, id: id, action: "modify", fields: .object(["recurrence": recurrence]))["error"]["code"], .string("unsupported_scope")) }
    }

    func testRecurringAndDetachedDeletionRecoversOnlyStandaloneCopyAndRetainsSource() throws {
        for detached in [false, true] {
            let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
            let created = commit(broker, create(broker, recurrence: rule(end: .object(["count": .int(2)]))))
            var second = backend.events[0]; second.occurrence = "2026-11-01T10:00:00.000Z"; second.fields.start = "2026-11-01T10:00:00.000Z"; second.fields.end = "2026-11-01T11:00:00.000Z"; backend.events.append(second)
            backend.events[0].detached = detached
            let id = call(broker, "get_event", ["event_id": created["result"]["event"]["id"]])["result"]["event"]["id"]
            let preview = draft(broker, id: id, action: "delete")["result"]["preview"], before = preview["envelope"]["before"]
            XCTAssertEqual(preview["envelope"]["recovery"]["limitations"], .array([.string(Broker.copyRecoveryLimitation), .string(Broker.recurringCopyRecoveryLimitation)]))
            let deleted = commit(broker, preview, action: "delete"), nonce = deleted["result"]["nonce"]
            XCTAssertEqual(deleted["result"]["state"], .string("applied")); XCTAssertEqual(backend.events, [second]); XCTAssertEqual(commit(broker, preview, action: "delete"), deleted)
            let source = try state.execution(nonce.string!)!.payload
            let plan = call(broker, "preflight_rollback", ["change_ids": .array([nonce])]), undo = plan["result"]["steps"].array![0]["preview"]
            XCTAssertEqual(undo["envelope"]["version"], .int(2)); XCTAssertTrue(undo["envelope"]["rollback"]["limitations"].array!.contains(.string(Broker.recurringCopyRecoveryLimitation)))
            XCTAssertEqual(call(broker, "commit_rollback", ["preview": undo])["result"]["state"], .string("applied"))
            XCTAssertEqual(backend.events[0], second); let copy = backend.events[1]
            XCTAssertNotEqual(copy.nativeID, second.nativeID); XCTAssertNil(copy.occurrence); XCTAssertFalse(copy.recurring); XCTAssertFalse(copy.detached); XCTAssertEqual(copy.fields.json, before["fields"])
            XCTAssertEqual(call(broker, "get_event", ["event_id": id])["result"]["event"]["recurring"], .bool(false))
            XCTAssertEqual(try state.execution(nonce.string!)!.payload, source)
            XCTAssertEqual(call(broker, "preflight_rollback", ["change_ids": .array([nonce])])["error"]["code"], .string("rollback_ineligible")); try state.verifyAudit()
        }
    }

    func testLegacyRecurringDeletesAndHistoryCannotInheritNewConsent() throws {
        for version in [1, 2] {
            let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
            let id = commit(broker, create(broker, recurrence: rule()))["result"]["event"]["id"]
            var envelope = draft(broker, id: id, action: "delete")["result"]["preview"]["envelope"].object!; envelope["version"] = .int(version); envelope.removeValue(forKey: "recovery")
            let payload = JSON.object(envelope), preview = try sign(payload, state: state)
            XCTAssertEqual(commit(broker, preview, action: "delete")["error"]["code"], .string("unsupported_restore")); XCTAssertEqual(backend.writeCount, 1)
            let nonce = payload["nonce"].string!, sequence = try state.claim(nonce: nonce, payload: payload, now: Date())
            _ = try backend.apply(action: "delete", calendarID: backend.events[0].calendarNativeID, existing: backend.events[0], fields: nil)
            try state.finish(nonce: nonce, state: "applied", result: .object(["nonce": .string(nonce), "state": .string("applied"), "action": .string("delete"), "deleted": .bool(true), "audit_sequence": .int(sequence)]), event: "write_applied")
            XCTAssertEqual(call(broker, "get_stored_change", ["change_id": .string(nonce)])["result"]["change"]["recovery_reason"], .string("recurring_deletion_cannot_be_faithfully_restored"))
            XCTAssertEqual(call(broker, "preflight_rollback", ["change_ids": .array([.string(nonce)])])["error"]["code"], .string("rollback_ineligible")); XCTAssertTrue(backend.events.isEmpty)
        }
    }

    func testRecurringDeleteRecoveryWarningTamperAndStaleRejectBeforeIntent() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
        let id = commit(broker, create(broker, recurrence: rule()))["result"]["event"]["id"]
        let preview = draft(broker, id: id, action: "delete")["result"]["preview"]
        var envelope = preview["envelope"].object!; envelope["recovery"] = .object(["mode": .string("standalone_copy"), "limitations": .array([.string(Broker.copyRecoveryLimitation)])])
        XCTAssertEqual(commit(broker, try sign(.object(envelope), state: state), action: "delete")["error"]["code"], .string("invalid_preview"))
        backend.events[0].fields.notes = "External change"
        XCTAssertEqual(commit(broker, preview, action: "delete")["error"]["code"], .string("stale_event")); XCTAssertEqual(backend.writeCount, 1)
        XCTAssertNil(try state.execution(preview["envelope"]["nonce"].string!))
    }

    func testProviderReadbackFailuresStayUnknownAndReplayDoesNotWriteAgain() throws {
        for corruption in ["drop", "interval", "selector", "detach"] {
            let state = try state(), backend = RecurrenceVerificationBackend(), broker = Broker(state: state, backend: backend); backend.corruption = corruption
            let preview = create(broker, recurrence: rule()), result = commit(broker, preview)
            XCTAssertEqual(result["result"]["state"], .string("unknown"), corruption); XCTAssertEqual(commit(broker, preview), result); XCTAssertEqual(backend.base.writeCount, 1)
            XCTAssertEqual(commit(broker, create(broker, recurrence: rule()))["error"]["code"], .string("unresolved_write")); XCTAssertEqual(backend.base.writeCount, 1)
        }
    }
}
