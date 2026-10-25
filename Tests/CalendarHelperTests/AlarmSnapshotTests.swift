import XCTest
import Foundation
import CryptoKit
@testable import CalendarCore

/// Reorders complete provider snapshots independently at read and write boundaries.
private final class ReorderingAlarmBackend: CalendarBackend {
    let base: SyntheticBackend
    var permuteReads = false, permuteWrites = false, corruptWrites = false
    private var reads = 0
    init(_ base: SyntheticBackend) { self.base = base }
    func calendars() throws -> [CalendarRecord] { try base.calendars() }
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] { try base.query(start: start, end: end, calendarIDs: calendarIDs) }
    private func observed(_ value: EventRecord) -> EventRecord {
        reads += 1; var record = value
        if permuteReads && reads % 2 == 1, var details = record.details.object, let alarms = details["alarms"]?.array {
            details["alarms"] = .array(alarms.reversed()); record.details = .object(details)
        }
        return record
    }
    private func afterWrite() {
        for index in base.events.indices {
            var details = base.events[index].details.object!, alarms = details["alarms"]?.array ?? []
            if permuteWrites { alarms.reverse() }
            if corruptWrites && !alarms.isEmpty { var alarm = alarms[0].object!; alarm["relative_offset"] = .string("-777.0"); alarms[0] = .object(alarm) }
            details["alarms"] = .array(alarms); base.events[index].details = .object(details)
        }
    }
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord { observed(try base.get(nativeID: nativeID, calendarID: calendarID, occurrence: occurrence, knownStart: knownStart)) }
    func firstSeriesOccurrence(for selected: EventRecord) throws -> EventRecord { observed(try base.firstSeriesOccurrence(for: selected)) }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? {
        let saved = try base.apply(action: action, calendarID: calendarID, existing: existing, fields: fields); afterWrite(); return saved
    }
    func applyRestoringAlarms(calendarID: String, existing: EventRecord, fields: EventFields, alarms: JSON) throws -> EventRecord? {
        let saved = try base.applyRestoringAlarms(calendarID: calendarID, existing: existing, fields: fields, alarms: alarms); afterWrite(); return saved
    }
    func restore(calendarID: String, fields: EventFields, details: JSON, availability: String) throws -> EventRecord {
        let saved = try base.restore(calendarID: calendarID, fields: fields, details: details, availability: availability); afterWrite(); return saved
    }
    func applySeriesFields(anchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?) throws -> EventRecord {
        // This synthetic provider's entry guard uses its own retained order; the live
        // provider canonicalizes both immediate records before its strict guard.
        let current = try base.firstSeriesOccurrence(for: anchor)
        let saved = try base.applySeriesFields(anchor: current, fields: fields, changedFields: changedFields, restoredAlarms: restoredAlarms); afterWrite(); return saved
    }
}

final class AlarmSnapshotTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() { for dir in directories { try? FileManager.default.removeItem(at: dir) }; super.tearDown() }
    private func store() throws -> StateStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-alarm-order-" + UUID().uuidString); directories.append(dir)
        let state = try StateStore(directory: dir); try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "d", count: 64)); return state
    }
    private func alarm(_ seconds: String) -> JSON { .object(["absolute_date": .null, "relative_offset": .string(seconds), "proximity": .int(0), "structured_location": .null, "type": .int(0), "email_address": .null, "sound_name": .null]) }
    private var alarms: JSON { .array([alarm("-300.0"), alarm("-300.0"), alarm("-3600.0")]) }
    private func fixture(series: Bool = false) throws -> SyntheticBackend {
        var details: [String: JSON] = ["alarms": alarms, "url": .null, "structured_location": .null]
        if series { details["recurrence_rules"] = .array([try EventRecurrence(json: .object(["frequency": .string("weekly")])).rawRule]) }
        return SyntheticBackend(events: [EventRecord(nativeID: "alarm-fixture", calendarNativeID: "synthetic-calendar", occurrence: series ? "2026-10-25T10:00:00.000Z" : nil, fields: EventFields(title: "Original", start: "2026-10-25T10:00:00.000Z", end: "2026-10-25T11:00:00.000Z", timeZone: "Europe/London", allDay: false), recurring: series, details: .object(details))])
    }
    private func call(_ broker: Broker, _ op: String, _ arguments: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(op), "arguments": .object(arguments)])) }
    private func id(_ broker: Broker) -> JSON { call(broker, "query_events", ["start": .string("2026-10-25T00:00:00Z"), "end": .string("2026-10-26T00:00:00Z")])["result"]["events"].array![0]["id"] }
    private func draft(_ broker: Broker, _ id: JSON, title: String, series: Bool = false) -> JSON { call(broker, "preflight_change", ["action": .string("modify"), "scope": .string(series ? "series" : "this"), "event_id": id, "fields": .object(["title": .string(title)])])["result"]["preview"] }
    private func sign(_ envelope: JSON, _ state: StateStore) throws -> JSON {
        let key = SymmetricKey(data: Data(base64Encoded: try state.metadata("signing_key")!)!)
        return .object(["envelope": envelope, "authentication_tag": .string(Data(HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: key)).base64EncodedString())])
    }
    private func fingerprint(_ body: [String: JSON]) throws -> JSON {
        var value = body; value.removeValue(forKey: "fingerprint"); value["fingerprint"] = .string(digest(try JSON.object(value).data())); return .object(value)
    }
    private func oldSnapshot(_ snapshot: JSON) throws -> JSON {
        if snapshot == .null { return .null }
        var body = snapshot.object!, details = body["details"]!.object!
        if let raw = details["alarms"]?.array { details["alarms"] = .array(raw.reversed()) }
        body["details"] = .object(details); return try fingerprint(body)
    }
    private func oldPreview(_ preview: JSON, _ state: StateStore, version: Int? = nil) throws -> JSON {
        var body = preview["envelope"].object!
        body["before"] = try oldSnapshot(body["before"]!)
        if var series = body["series"]?.object { series["selected"] = try oldSnapshot(series["selected"]!); body["series"] = .object(series) }
        if var rollback = body["rollback"]?.object {
            if let raw = rollback["alarm_restoration"]?.array { rollback["alarm_restoration"] = .array(raw.reversed()) }
            if var restoration = rollback["restoration"]?.object, var details = restoration["details"]?.object, let raw = details["alarms"]?.array {
                details["alarms"] = .array(raw.reversed()); restoration["details"] = .object(details); rollback["restoration"] = .object(restoration)
            }
            if version == 1 { rollback.removeValue(forKey: "alarm_restoration") }
            body["rollback"] = .object(rollback)
        }
        if let version { body["version"] = .int(version); if version < 3 { body.removeValue(forKey: "recovery") } }
        return try sign(.object(body), state)
    }
    private func undoPreview(_ broker: Broker, _ changes: [JSON]) -> JSON { call(broker, "preflight_rollback", ["change_ids": .array(changes)])["result"]["steps"].array!.first!["preview"] }
    private func historicalRows(_ state: StateStore) throws -> [[String]] {
        try state.rows("SELECT nonce,payload,result FROM executions ORDER BY rowid") + state.rows("SELECT nonce,payload_cipher,result_cipher FROM execution_details ORDER BY rowid") + state.rows("SELECT nonce,key FROM execution_keys ORDER BY rowid")
    }

    func testLosslessCanonicalSnapshotsAndStrictNonAlarmContent() throws {
        let base = try fixture(); let record = base.events[0], calendar = CalendarRecord(nativeID: "c", title: "C", source: "S").view(id: "calendar")
        let a = try record.view(id: "event", calendar: calendar)
        var reordered = record; var details = record.details.object!; details["alarms"] = .array(alarms.array!.reversed()); reordered.details = .object(details)
        XCTAssertNotEqual(reordered.details["alarms"], record.details["alarms"])
        XCTAssertEqual(try reordered.view(id: "event", calendar: calendar), a)
        XCTAssertEqual(a["details"]["alarms"].array?.count, 3)
        let legacy = try oldSnapshot(a); XCTAssertNotEqual(legacy, a); XCTAssertTrue(EventSnapshot.equivalent(legacy, a))
        for mutation in 0..<7 {
            var changed = a.object!, extra = changed["details"]!.object!, values = extra["alarms"]!.array!, raw = values[0].object!
            switch mutation {
            case 0: values.removeLast()
            case 1: raw["relative_offset"] = .string("-300")
            case 2: raw["extra"] = .null
            case 3: raw.removeValue(forKey: "sound_name")
            case 4: raw["structured_location"] = .object(["points": .array([.int(1), .int(2)])])
            case 5: extra["attendees"] = .array([.string("different")])
            default: changed["status"] = .string("tentative")
            }
            if mutation != 0 { values[0] = .object(raw) }; extra["alarms"] = .array(values); changed["details"] = .object(extra)
            XCTAssertFalse(EventSnapshot.equivalent(try fingerprint(changed), a), "mutation \(mutation)")
        }
        var left = alarm("-300.0").object!, right = left
        left["unknown"] = .array([.int(1), .int(2)]); right["unknown"] = .array([.int(2), .int(1)])
        XCTAssertFalse(EventSnapshot.alarmsEquivalent(.array([.object(left)]), .array([.object(right)])))
        XCTAssertThrowsError(try EventSnapshot.canonicalAlarms(.array([.string("bad")])))
        XCTAssertFalse(EventSnapshot.alarmsEquivalent(.array([.string("bad")]), .array([.string("bad")])))
        for raw: JSON? in [nil, .null, .array([])] {
            var body = a.object!, d = body["details"]!.object!; d["alarms"] = raw; body["details"] = .object(d)
            let snapshot = try fingerprint(body)
            for other: JSON? in [nil, .null, .array([])] where raw != other {
                var otherBody = body, otherDetails = d; otherDetails["alarms"] = other; otherBody["details"] = .object(otherDetails)
                XCTAssertFalse(EventSnapshot.equivalent(snapshot, try fingerprint(otherBody)))
            }
        }
        var invalid = legacy.object!; invalid["fingerprint"] = .string(String(repeating: "0", count: 64))
        XCTAssertFalse(EventSnapshot.equivalent(.object(invalid), a)); XCTAssertFalse(EventSnapshot.equivalent(.object(invalid), .object(invalid)))
        var malformed = a.object!, malformedDetails = malformed["details"]!.object!
        malformedDetails["alarms"] = .array([.string("bad")]); malformed["details"] = .object(malformedDetails)
        let malformedSnapshot = try fingerprint(malformed)
        XCTAssertFalse(EventSnapshot.equivalent(malformedSnapshot, malformedSnapshot))
    }

    func testLegacyV1V2V3SignedOrdinaryPreviewsKeepOriginalPayloadAndReplayIdentity() throws {
        for version in [1, 2, 3] {
            let state = try store(), base = try fixture(), backend = ReorderingAlarmBackend(base), broker = Broker(state: state, backend: backend), eventID = id(broker)
            backend.permuteReads = true; backend.permuteWrites = true
            let old = try oldPreview(draft(broker, eventID, title: "Changed"), state, version: version), original = old["envelope"]
            let result = call(broker, "commit_modify", ["preview": old]); XCTAssertEqual(result["result"]["state"], .string("applied"), "v\(version): \(result)")
            let nonce = result["result"]["nonce"].string!
            XCTAssertEqual(try state.execution(nonce)!.payload, original)
            XCTAssertEqual(call(broker, "commit_modify", ["preview": old]), result)
            var alternative = original.object!; alternative["before"] = try oldSnapshot(original["before"])
            XCTAssertEqual(call(broker, "commit_modify", ["preview": try sign(.object(alternative), state)])["error"]["code"], .string("nonce_conflict"))
            XCTAssertEqual(base.writeCount, 1); XCTAssertEqual(try state.metadata("recovery_storage_version"), "4"); try state.verifyAudit()
        }
    }

    func testInvalidOriginalFingerprintHMACAndRealAlarmChangeRejectBeforeIntent() throws {
        let state = try store(), base = try fixture(), broker = Broker(state: state, backend: base), eventID = id(broker), preview = try oldPreview(draft(broker, eventID, title: "Changed"), state)
        var envelope = preview["envelope"].object!, before = envelope["before"]!.object!; before["fingerprint"] = .string("invalid"); envelope["before"] = .object(before)
        XCTAssertEqual(call(broker, "commit_modify", ["preview": try sign(.object(envelope), state)])["error"]["code"], .string("stale_event"))
        var unauthenticated = preview.object!; unauthenticated["envelope"] = .object(envelope)
        XCTAssertEqual(call(broker, "commit_modify", ["preview": .object(unauthenticated)])["error"]["code"], .string("invalid_preview"))
        var details = base.events[0].details.object!, raw = details["alarms"]!.array!; raw.removeLast(); details["alarms"] = .array(raw); base.events[0].details = .object(details)
        XCTAssertEqual(call(broker, "commit_modify", ["preview": preview])["error"]["code"], .string("stale_event"))
        XCTAssertEqual(base.writeCount, 0); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
    }

    func testLegacyHistoryBridgesAndV1V2RollbackPreserveStoredBytes() throws {
        for rollbackVersion in [1, 2] {
            let state = try store(), base = try fixture(), backend = ReorderingAlarmBackend(base), broker = Broker(state: state, backend: backend), eventID = id(broker)
            var nonces: [JSON] = []
            // Simulate two older helper completions, whose full snapshots used provider order.
            for index in 1...2 {
                let preview = try oldPreview(draft(broker, eventID, title: "Change \(index)"), state, version: index), payload = preview["envelope"], nonce = payload["nonce"].string!
                let sequence = try state.claim(nonce: nonce, payload: payload, now: Date())
                base.events[0].fields.title = "Change \(index)"
                let current = call(broker, "get_event", ["event_id": eventID])["result"]["event"]
                let result: JSON = .object(["nonce": .string(nonce), "state": .string("applied"), "action": .string("modify"), "event": index == 1 ? current : try oldSnapshot(current), "audit_sequence": .int(sequence)])
                try state.finish(nonce: nonce, state: "applied", result: result, event: "write_applied"); nonces.append(.string(nonce))
            }
            let sources = try broker.selectedRows(.object(["change_ids": .array(nonces)])), digestBefore = try broker.sourceDigest(sources)
            let rowsBefore = try historicalRows(state), storedBefore = nonces.map { call(broker, "get_stored_change", ["change_id": $0]) }
            backend.permuteReads = true; backend.permuteWrites = true
            let undo = try oldPreview(undoPreview(broker, nonces), state, version: rollbackVersion)
            XCTAssertEqual(call(broker, "commit_rollback", ["preview": undo])["result"]["state"], .string("applied"))
            XCTAssertEqual(base.events[0].fields.title, "Original"); XCTAssertTrue(EventSnapshot.alarmsEquivalent(base.events[0].details["alarms"], alarms))
            XCTAssertEqual(try broker.sourceDigest(sources), digestBefore)
            XCTAssertEqual(Array(try historicalRows(state).prefix(2)), Array(rowsBefore.prefix(2)))
            for (index, nonce) in nonces.enumerated() {
                let storedAfter = call(broker, "get_stored_change", ["change_id": nonce])
                for key in ["before", "proposed_after", "observed_after", "execution_result"] { XCTAssertEqual(storedAfter["result"][key], storedBefore[index]["result"][key]) }
            }
            // Per-source ciphertexts and keys remain identical after adding the rollback.
            XCTAssertEqual(try state.rows("SELECT nonce,payload_cipher,result_cipher FROM execution_details WHERE nonce IN (?,?) ORDER BY rowid", nonces.compactMap(\.string)), Array(rowsBefore[2..<4]))
            XCTAssertEqual(try state.rows("SELECT nonce,key FROM execution_keys WHERE nonce IN (?,?) ORDER BY rowid", nonces.compactMap(\.string)), Array(rowsBefore[4..<6]))
            try state.verifyAudit()
        }
    }

    func testOldDeleteRecoveryRestorationAcceptsPermutationWithoutMetadataLoss() throws {
        let state = try store(), base = try fixture(), backend = ReorderingAlarmBackend(base), broker = Broker(state: state, backend: backend), eventID = id(broker)
        let deletion = call(broker, "preflight_change", ["action": .string("delete"), "scope": .string("this"), "event_id": eventID])["result"]["preview"]
        let result = call(broker, "commit_delete", ["preview": try oldPreview(deletion, state)])
        XCTAssertEqual(result["result"]["state"], .string("applied"))
        let undo = try oldPreview(undoPreview(broker, [result["result"]["nonce"]]), state)
        backend.permuteWrites = true; backend.permuteReads = true
        XCTAssertEqual(call(broker, "commit_rollback", ["preview": undo])["result"]["state"], .string("applied"))
        XCTAssertTrue(EventSnapshot.alarmsEquivalent(base.events[0].details["alarms"], alarms))
    }

    func testV4SeriesAndInverseAcceptLegacyOrderRetainExactSources() throws {
        let state = try store(), base = try fixture(series: true), backend = ReorderingAlarmBackend(base), broker = Broker(state: state, backend: backend), eventID = id(broker)
        backend.permuteReads = true; backend.permuteWrites = true
        let preview = try oldPreview(draft(broker, eventID, title: "New defaults", series: true), state)
        let changed = call(broker, "commit_series_modify", ["preview": preview]); XCTAssertEqual(changed["result"]["state"], .string("applied"))
        let nonce = changed["result"]["nonce"].string!, payload = try state.execution(nonce)!.payload, result = try state.execution(nonce)!.result
        let source = try broker.selectedRows(.object(["change_ids": .array([.string(nonce)])])), beforeDigest = try broker.sourceDigest(source)
        let undo = try oldPreview(undoPreview(broker, [.string(nonce)]), state)
        XCTAssertEqual(call(broker, "commit_series_rollback", ["preview": undo])["result"]["state"], .string("applied"))
        XCTAssertEqual(base.events[0].fields.title, "Original"); XCTAssertEqual(try state.execution(nonce)!.payload, payload); XCTAssertEqual(try state.execution(nonce)!.result, result)
        XCTAssertEqual(try broker.sourceDigest(source), beforeDigest); XCTAssertEqual(payload, preview["envelope"]); XCTAssertEqual(base.writeCount, 2)
        try state.verifyAudit()
    }

    func testLegacyV4RetainedResultAndAlarmInverseKeepDuplicatesAndExactHistory() throws {
        let state = try store(), base = try fixture(series: true), backend = ReorderingAlarmBackend(base), broker = Broker(state: state, backend: backend), eventID = id(broker)
        let alerts: JSON = .array([.object(["relative_minutes": .int(-10)]), .object(["relative_minutes": .int(-20)])])
        let proposed = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("series"), "event_id": eventID, "fields": .object(["alerts": alerts])])["result"]["preview"]
        let original = try oldPreview(proposed, state), payload = original["envelope"], nonce = payload["nonce"].string!
        let sequence = try state.claim(nonce: nonce, payload: payload, now: Date())
        var details = base.events[0].details.object!; details["alarms"] = .array(try EventAlert.parse(alerts).map(\.rawAlarm)); base.events[0].details = .object(details)
        let observed = try oldSnapshot(call(broker, "get_event", ["event_id": eventID])["result"]["event"])
        let result: JSON = .object(["nonce": .string(nonce), "state": .string("applied"), "action": .string("modify"), "event": observed, "audit_sequence": .int(sequence)])
        try state.finish(nonce: nonce, state: "applied", result: result, event: "write_applied")
        let history = try historicalRows(state), source = try broker.selectedRows(.object(["change_ids": .array([.string(nonce)])])), sourceDigest = try broker.sourceDigest(source)
        backend.permuteReads = true; backend.permuteWrites = true
        let undo = try oldPreview(undoPreview(broker, [.string(nonce)]), state)
        XCTAssertEqual(undo["envelope"]["rollback"]["alarm_restoration"].array?.count, 3)
        XCTAssertEqual(call(broker, "commit_series_rollback", ["preview": undo])["result"]["state"], .string("applied"))
        XCTAssertTrue(EventSnapshot.alarmsEquivalent(base.events[0].details["alarms"], alarms)); XCTAssertEqual(base.events[0].details["alarms"].array?.count, 3)
        XCTAssertEqual(try state.execution(nonce)!.payload, payload); XCTAssertEqual(try state.execution(nonce)!.result, result)
        XCTAssertEqual(try broker.sourceDigest(source), sourceDigest)
        XCTAssertEqual(try state.rows("SELECT nonce,payload_cipher,result_cipher FROM execution_details WHERE nonce=?", [nonce]), [history[1]])
        XCTAssertEqual(try state.rows("SELECT nonce,key FROM execution_keys WHERE nonce=?", [nonce]), [history[2]])
        XCTAssertEqual(try state.metadata("recovery_storage_version"), "4"); try state.verifyAudit()
    }

    func testRealAlarmChangeDuringRestorationStaysUnknown() throws {
        for series in [false, true] {
            let state = try store(), base = try fixture(series: series), backend = ReorderingAlarmBackend(base), broker = Broker(state: state, backend: backend), eventID = id(broker)
            let preview: JSON
            if series {
                preview = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("series"), "event_id": eventID, "fields": .object(["alerts": .array([])])])["result"]["preview"]
            } else { preview = draft(broker, eventID, title: "Changed") }
            let op = series ? "commit_series_modify" : "commit_modify", applied = call(broker, op, ["preview": preview])
            XCTAssertEqual(applied["result"]["state"], .string("applied"))
            let undo = undoPreview(broker, [applied["result"]["nonce"]]); backend.corruptWrites = true
            let undoOp = series ? "commit_series_rollback" : "commit_rollback", result = call(broker, undoOp, ["preview": undo])
            XCTAssertEqual(result["result"]["state"], .string("unknown")); XCTAssertEqual(call(broker, undoOp, ["preview": undo]), result)
            XCTAssertEqual(base.writeCount, 2); XCTAssertTrue(try state.hasUnresolved())
        }
    }

    func testRealPostWriteAlarmChangeStaysUnknownAndBlocksFreshWrites() throws {
        for series in [false, true] {
            let state = try store(), base = try fixture(series: series), backend = ReorderingAlarmBackend(base), broker = Broker(state: state, backend: backend), eventID = id(broker)
            backend.corruptWrites = true
            let preview = draft(broker, eventID, title: "Uncertain", series: series), op = series ? "commit_series_modify" : "commit_modify"
            let result = call(broker, op, ["preview": preview]); XCTAssertEqual(result["result"]["state"], .string("unknown")); XCTAssertEqual(call(broker, op, ["preview": preview]), result)
            let next = draft(broker, eventID, title: "Blocked", series: series)
            XCTAssertEqual(call(broker, op, ["preview": next])["error"]["code"], .string("unresolved_write")); XCTAssertEqual(base.writeCount, 1)
            XCTAssertEqual(try state.metadata("recovery_storage_version"), "4"); try state.verifyAudit()
        }
    }
}
