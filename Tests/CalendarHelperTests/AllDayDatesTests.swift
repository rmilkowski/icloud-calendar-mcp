import XCTest
import Foundation
import CryptoKit
@testable import CalendarCore

private final class AllDayClock { var value = Date().addingTimeInterval(3600) }
private final class AllDayProbeBackend: CalendarBackend {
    let base: SyntheticBackend
    var beforeWrite: (() -> Void)?, afterWrite: (() -> Void)?, onGet: (() -> Void)?
    var corrupt: ((inout EventRecord, AllDayInterval) -> Void)?
    init(_ base: SyntheticBackend = SyntheticBackend()) { self.base = base }
    func allDayProjectionTimeZone() throws -> String { try base.allDayProjectionTimeZone() }
    func calendars() throws -> [CalendarRecord] { try base.calendars() }
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] { try base.query(start: start, end: end, calendarIDs: calendarIDs) }
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord { onGet?(); return try base.get(nativeID: nativeID, calendarID: calendarID, occurrence: occurrence, knownStart: knownStart) }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? { try base.apply(action: action, calendarID: calendarID, existing: existing, fields: fields) }
    func applyAllDay(calendarID: String, existing: EventRecord?, fields: EventFields, interval: AllDayInterval, restoredAlarms: JSON?) throws -> EventRecord {
        beforeWrite?()
        let saved = try base.applyAllDay(calendarID: calendarID, existing: existing, fields: fields, interval: interval, restoredAlarms: restoredAlarms)
        if let index = base.events.firstIndex(where: { $0.nativeID == saved.nativeID }) { corrupt?(&base.events[index], interval) }
        afterWrite?()
        return try base.get(nativeID: saved.nativeID, calendarID: saved.calendarNativeID, occurrence: saved.occurrence, knownStart: parseDate(saved.fields.start))
    }
}

final class AllDayDatesTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at: directory) }; super.tearDown() }
    private func state(_ directory: URL? = nil) throws -> StateStore {
        let directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("calendar-civil-dates-" + UUID().uuidString)
        if !directories.contains(directory) { directories.append(directory) }
        let state = try StateStore(directory: directory); try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "d", count: 64)); return state
    }
    private func call(_ broker: Broker, _ operation: String, _ args: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(operation), "arguments": .object(args)])) }
    private func dates(_ start: String = "2026-10-26", _ end: String = "2026-11-02") -> JSON { .object(["start_date": .string(start), "end_date_exclusive": .string(end)]) }
    private func draft(_ broker: Broker, id: JSON? = nil, dateFields: JSON? = nil, metadata: [String: JSON] = [:]) -> JSON {
        var fields = metadata; fields["all_day_dates"] = dateFields ?? dates()
        if id == nil, fields["title"] == nil { fields["title"] = .string("Synthetic civil interval") }
        var args: [String: JSON] = ["action": .string(id == nil ? "create" : "modify"), "scope": .string("this"), "fields": .object(fields)]
        if let id { args["event_id"] = id }
        else { args["calendar_id"] = call(broker, "list_calendars")["result"]["calendars"].array!.first!["id"] }
        return call(broker, "preflight_change", args)
    }
    private func commit(_ broker: Broker, _ response: JSON, action: String = "create") -> JSON { call(broker, "commit_" + action, ["preview": response["result"]["preview"]]) }
    private func sign(_ envelope: JSON, state: StateStore) throws -> JSON {
        let key = SymmetricKey(data: Data(base64Encoded: try XCTUnwrap(state.metadata("signing_key")))!)
        return .object(["envelope": envelope, "authentication_tag": .string(Data(HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: key)).base64EncodedString())])
    }
    private func fixture(endExclusive: Bool = false) throws -> SyntheticBackend {
        let interval = try AllDayInterval(dates("2026-10-25", "2026-11-03"), projectionTimeZone: "Europe/London")
        var fields = interval.materialized(EventFields(title: "Original synthetic interval", start: "", end: "", timeZone: nil, allDay: true, location: "Location", notes: "Notes"))
        if endExclusive { fields.end = iso(interval.endExclusive) }
        let alarm: JSON = .object(["absolute_date": .null, "relative_offset": .string("-300.0"), "proximity": .int(0), "structured_location": .null, "type": .int(1), "email_address": .null, "sound_name": .string("Synthetic sound")])
        return SyntheticBackend(events: [EventRecord(nativeID: "civil-fixture", calendarNativeID: "synthetic-calendar", fields: fields, details: .object(["alarms": .array([alarm]), "url": .string("https://example.invalid/fixture"), "structured_location": .object(["title": .string("Location"), "radius": .string("0.0")]), "recurrence_rules": .array([])]))])
    }
    private func id(_ broker: Broker) throws -> JSON {
        let response = call(broker, "query_events", ["start": .string("2026-10-01T00:00:00Z"), "end": .string("2026-12-01T00:00:00Z")])
        return try XCTUnwrap(response["result"]["events"].array?.first?["id"])
    }
    private func undoDraft(_ broker: Broker, _ nonce: JSON) -> JSON { call(broker, "preflight_rollback", ["change_ids": .array([nonce])]) }

    func testStrictCalendarDatesDSTNonHourZonesLeapAndBounds() throws {
        for (start, end, zone, hours) in [("2026-10-25", "2026-10-26", "Europe/London", 25.0), ("2026-03-29", "2026-03-30", "Europe/London", 23.0), ("2026-01-01", "2026-01-02", "Asia/Kathmandu", 24.0), ("2028-02-29", "2028-03-01", "UTC", 24.0)] {
            let value = try AllDayInterval(dates(start, end), projectionTimeZone: zone)
            XCTAssertEqual(value.endExclusive.timeIntervalSince(value.start), hours * 3600)
            XCTAssertEqual(value.endExclusive.timeIntervalSince(value.writeEnd), 1)
        }
        XCTAssertNoThrow(try AllDayInterval(dates("2024-01-01", "2025-01-01"), projectionTimeZone: "UTC"))
        XCTAssertNoThrow(try AllDayInterval(dates("2026-03-28", "2027-03-29"), projectionTimeZone: "Europe/London"))
        XCTAssertEqual(try AllDayInterval.civilOrdinal("0001-01-01"), 0)
        XCTAssertEqual(try AllDayInterval.civilOrdinal("9999-12-31"), 3_652_058)
        XCTAssertThrowsError(try AllDayInterval(dates("0001-01-01", "0001-01-02"), projectionTimeZone: "UTC"))
        XCTAssertNoThrow(try AllDayInterval(dates("9999-12-30", "9999-12-31"), projectionTimeZone: "UTC"))
        XCTAssertNoThrow(try AllDayInterval(dates("2011-12-29", "2012-12-29"), projectionTimeZone: "Pacific/Apia"))
        XCTAssertThrowsError(try AllDayInterval(dates("2011-12-29", "2012-12-30"), projectionTimeZone: "Pacific/Apia"))
        XCTAssertEqual(try AllDayInterval.civilOrdinal("1583-10-11") - AllDayInterval.civilOrdinal("1582-09-30"), 376)
        XCTAssertEqual(try AllDayInterval.civilOrdinal("1583-10-01") - AllDayInterval.civilOrdinal("1582-09-30"), 366)
        XCTAssertThrowsError(try AllDayInterval(dates("1582-09-30", "1583-10-11"), projectionTimeZone: "UTC"))
        XCTAssertThrowsError(try AllDayInterval.civilOrdinal("1500-02-29"))
        XCTAssertNoThrow(try AllDayInterval(dates("1600-02-29", "1600-03-01"), projectionTimeZone: "UTC"))
        // Foundation's historical cutover can disagree even for valid Gregorian
        // labels; do not silently project those labels as Julian calendar dates.
        XCTAssertThrowsError(try AllDayInterval.midnight("1500-02-28", zone: TimeZone(secondsFromGMT: 0)!))
        XCTAssertThrowsError(try AllDayInterval.midnight("1582-09-30", zone: TimeZone(secondsFromGMT: 0)!))
        var historical = Calendar(identifier: .gregorian); historical.timeZone = TimeZone(secondsFromGMT: 0)!
        let historicalDate = try XCTUnwrap(historical.date(from: DateComponents(year: 1500, month: 2, day: 28, hour: 0)))
        XCTAssertThrowsError(try AllDayInterval.label(historicalDate, zone: historical.timeZone))
        for (start, end, zone) in [("2026-02-30", "2026-03-02", "UTC"), ("0000-01-01", "0001-01-01", "UTC"), ("2026-01-01", "2027-01-03", "UTC"), ("2026-01-02", "2026-01-02", "UTC"), ("2011-12-30", "2011-12-31", "Pacific/Apia"), ("2015-11-01", "2015-11-02", "America/Havana")] {
            XCTAssertThrowsError(try AllDayInterval(dates(start, end), projectionTimeZone: zone), "\(start)/\(zone)")
        }
    }
    func testAllDayAssignmentOrderEstablishesFloatingStateBeforeEndpoints() throws {
        let interval = try AllDayInterval(dates(), projectionTimeZone: "Europe/London")
        var operations: [String] = [], start: Date?, end: Date?
        interval.assign(setAllDay: { XCTAssertTrue($0); operations.append("all_day") }, setTimeZone: { XCTAssertNil($0); operations.append("time_zone") }, setStart: { start = $0; operations.append("start") }, setEnd: { end = $0; operations.append("end") })
        XCTAssertEqual(operations, ["all_day", "time_zone", "start", "end"])
        XCTAssertEqual(start, interval.start); XCTAssertEqual(end, interval.writeEnd)
    }
    func testCreateExactCapabilityBothProviderStylesAndRawObservedHistoryReplay() throws {
        for exclusive in [false, true] {
            let state = try state(), backend = SyntheticBackend(); backend.allDayUsesExclusiveEnd = exclusive
            let broker = Broker(state: state, backend: backend)
            XCTAssertEqual(call(broker, "all_day_dates_capabilities")["result"], Broker.allDayDatesCapabilities)
            XCTAssertEqual(call(broker, "recovery_capabilities")["result"]["storage_version"], .int(7))
            let response = draft(broker), preview = response["result"]["preview"], envelope = preview["envelope"]
            XCTAssertEqual(response["error"], .null, "\(response)")
            XCTAssertEqual(envelope["version"], .int(7)); XCTAssertEqual(envelope["all_day"]["after"], dates())
            XCTAssertEqual(envelope["after"]["end"], .string("2026-11-01T23:59:59.000Z"))
            XCTAssertEqual(envelope["after"]["time_zone"], .null)
            let result = commit(broker, response)
            XCTAssertEqual(result["result"]["state"], .string("applied"), "\(result)")
            XCTAssertEqual(result["result"]["event"]["fields"]["end"], .string(exclusive ? "2026-11-02T00:00:00.000Z" : "2026-11-01T23:59:59.000Z"))
            XCTAssertEqual(commit(broker, response), result); XCTAssertEqual(backend.writeCount, 1)
            let stored = try XCTUnwrap(state.execution(try XCTUnwrap(envelope["nonce"].string)))
            XCTAssertEqual(stored.payload, envelope); XCTAssertEqual(stored.result, result["result"])
            XCTAssertNotEqual(undoDraft(broker, result["result"]["nonce"])["error"], .null)
            try state.verifyAudit()
        }
    }
    func testCreatePlainLocationWrappersRetainExactRawSnapshotsAndFingerprints() throws {
        for location in ["", "Synthetic plain place"] {
            for exclusive in [false, true] {
                let state = try state(), backend = AllDayProbeBackend(), broker = Broker(state: state, backend: backend)
                backend.base.allDayUsesExclusiveEnd = exclusive
                let wrapper: JSON = .object(["title": .string(location), "radius": .string("0.0")])
                backend.corrupt = { event, _ in
                    var details = event.details.object!; details["structured_location"] = wrapper; event.details = .object(details)
                }
                let response = draft(broker, metadata: ["location": .string(location)]), result = commit(broker, response)
                XCTAssertEqual(result["result"]["state"], .string("applied"), "\(result)")
                let observed = try XCTUnwrap(backend.base.events.first), view = try broker.view(observed)
                XCTAssertEqual(result["result"]["event"], view)
                XCTAssertEqual(view["details"]["structured_location"], wrapper)
                var absent = observed, details = observed.details.object!
                details["structured_location"] = .null; absent.details = .object(details)
                XCTAssertNotEqual(view["fingerprint"], try broker.view(absent)["fingerprint"])
                let nonce = try XCTUnwrap(result["result"]["nonce"].string), stored = try XCTUnwrap(state.execution(nonce))
                XCTAssertEqual(stored.payload, response["result"]["preview"]["envelope"])
                XCTAssertEqual(stored.result, result["result"])
                XCTAssertEqual(stored.result["event"]["details"]["structured_location"], wrapper)
                XCTAssertEqual(commit(broker, response), result); XCTAssertEqual(backend.base.writeCount, 1)
                try state.verifyAudit()
            }
        }
    }
    func testCreateRejectsEveryOtherStructuredLocationShapeAndReplaysUnknown() throws {
        let location = "Synthetic plain place", plain: [String: JSON] = ["title": .string("Synthetic plain place"), "radius": .string("0.0")]
        var invalid: [JSON] = [.object([:]), .array([]), .string(location)]
        for (key, value): (String, JSON) in [("title", .string("Different")), ("title", .null), ("radius", .string("1.0")), ("radius", .string("0")), ("radius", .string("-0.0")), ("radius", .string(" 0.0")), ("radius", .int(0)), ("radius", .null), ("latitude", .string("0.0")), ("latitude", .null), ("longitude", .null), ("extra", .null)] {
            var wrapper = plain; wrapper[key] = value; invalid.append(.object(wrapper))
        }
        for missing in ["title", "radius"] { var wrapper = plain; wrapper.removeValue(forKey: missing); invalid.append(.object(wrapper)) }
        for wrapper in invalid {
            let state = try state(), backend = AllDayProbeBackend(), broker = Broker(state: state, backend: backend)
            backend.corrupt = { event, _ in
                var details = event.details.object!; details["structured_location"] = wrapper; event.details = .object(details)
            }
            let response = draft(broker, metadata: ["location": .string(location)]), result = commit(broker, response)
            XCTAssertEqual(result["result"]["state"], .string("unknown"), "\(wrapper): \(result)")
            XCTAssertEqual(commit(broker, response), result); XCTAssertEqual(backend.base.writeCount, 1)
            XCTAssertEqual(commit(broker, draft(broker))["error"]["code"], .string("unresolved_write"))
            try state.verifyAudit()
        }
    }
    func testHistoricalV7UnknownWithPlainWrapperRemainsUnknownAndBlocksRelatedWrites() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
        let response = draft(broker), envelope = response["result"]["preview"]["envelope"], nonce = try XCTUnwrap(envelope["nonce"].string)
        let (interval, fields) = try broker.validateAllDayEnvelope(envelope, rollback: false)
        let sequence = try state.claim(nonce: nonce, payload: envelope, now: Date())
        _ = try backend.applyAllDay(calendarID: "synthetic-calendar", existing: nil, fields: fields, interval: interval, restoredAlarms: nil)
        var details = backend.events[0].details.object!
        details["structured_location"] = .object(["title": .string(""), "radius": .string("0.0")]); backend.events[0].details = .object(details)
        let historical: JSON = .object(["nonce": .string(nonce), "state": .string("unknown"), "action": .string("create"), "audit_sequence": .int(sequence), "message": .string("Retained synthetic historical verification failure")])
        try state.finish(nonce: nonce, state: "unknown", result: historical, event: "write_unknown")
        let tables = ["executions", "execution_details", "execution_keys", "write_safety_claims", "audit", "recovery_links"]
        let proof = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try state.rows("SELECT * FROM " + $0 + " ORDER BY rowid")) })
        XCTAssertEqual(commit(broker, response)["result"], historical)
        XCTAssertEqual(commit(broker, draft(broker))["error"]["code"], .string("unresolved_write"))
        XCTAssertEqual(backend.writeCount, 1)
        for table in tables { XCTAssertEqual(try state.rows("SELECT * FROM " + table + " ORDER BY rowid"), proof[table]) }
        XCTAssertEqual(try state.execution(nonce)?.payload, envelope)
        XCTAssertEqual(try state.execution(nonce)?.result, historical)
        try state.verifyAudit()
    }
    func testModifyAndInverseStillRequireExactStructuredLocationPreservation() throws {
        for inverse in [false, true] {
            let state = try state(), backend = AllDayProbeBackend(try fixture()), broker = Broker(state: state, backend: backend)
            let response = draft(broker, id: try id(broker))
            let target: JSON
            if inverse {
                let applied = commit(broker, response, action: "modify")
                XCTAssertEqual(applied["result"]["state"], .string("applied"))
                target = try XCTUnwrap(undoDraft(broker, applied["result"]["nonce"])["result"]["steps"].array?.first?["preview"])
            } else { target = response["result"]["preview"] }
            backend.corrupt = { event, _ in
                var details = event.details.object!; details["structured_location"] = .null; event.details = .object(details)
            }
            let operation = inverse ? "commit_rollback" : "commit_modify"
            let result = call(broker, operation, ["preview": target])
            XCTAssertEqual(result["result"]["state"], .string("unknown"))
            XCTAssertEqual(call(broker, operation, ["preview": target]), result)
            XCTAssertEqual(backend.base.writeCount, inverse ? 2 : 1)
            try state.verifyAudit()
        }
    }
    func testNamedTimestampCreateUpgradesToV7AndRecurringCreateFailsBeforeIntent() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
        let calendar = call(broker, "list_calendars")["result"]["calendars"].array!.first!["id"]
        var fields: [String: JSON] = ["title": .string("Legacy timestamp input"), "start": .string("2026-10-25T00:00:00+01:00"), "end": .string("2026-11-02T00:00:00Z"), "time_zone": .string("Europe/London"), "all_day": .bool(true)]
        let response = call(broker, "preflight_change", ["action": .string("create"), "scope": .string("this"), "calendar_id": calendar, "fields": .object(fields)])
        XCTAssertEqual(response["result"]["preview"]["envelope"]["version"], .int(7))
        XCTAssertEqual(response["result"]["preview"]["envelope"]["all_day"]["after"], dates("2026-10-25", "2026-11-02"))
        fields["recurrence"] = .object(["frequency": .string("daily")])
        XCTAssertNotEqual(call(broker, "preflight_change", ["action": .string("create"), "scope": .string("series"), "calendar_id": calendar, "fields": .object(fields)])["error"], .null)
        XCTAssertEqual(backend.writeCount, 0); XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "0")
    }
    func testDateCorrectionInverseRestoresCivilDatesMetadataAndFullRawAlarms() throws {
        for originalExclusive in [false, true] {
            let state = try state(), backend = try fixture(endExclusive: originalExclusive), original = backend.events[0], broker = Broker(state: state, backend: backend)
            let response = draft(broker, id: try id(broker), metadata: ["title": .string("Changed"), "notes": .string("Changed notes"), "alerts": .array([])])
            let result = commit(broker, response, action: "modify")
            XCTAssertEqual(result["result"]["state"], .string("applied"), "\(result)")
            let source = try XCTUnwrap(state.execution(try XCTUnwrap(result["result"]["nonce"].string)))
            let plan = undoDraft(broker, result["result"]["nonce"])
            XCTAssertEqual(plan["error"], .null, "\(plan)")
            let inverse = try XCTUnwrap(plan["result"]["steps"].array?.first?["preview"])
            XCTAssertEqual(inverse["envelope"]["version"], .int(7)); XCTAssertEqual(inverse["envelope"]["after"].object?.count, 7)
            XCTAssertEqual(inverse["envelope"]["rollback"]["alarm_restoration"], original.details["alarms"])
            backend.allDayUsesExclusiveEnd = !originalExclusive
            let restored = call(broker, "commit_rollback", ["preview": inverse])
            XCTAssertEqual(restored["result"]["state"], .string("applied"), "\(restored)")
            XCTAssertEqual(try AllDayInterval.observed(backend.events[0].fields, projectionTimeZone: "Europe/London").json, dates("2026-10-25", "2026-11-03"))
            XCTAssertEqual(backend.events[0].fields.title, original.fields.title); XCTAssertEqual(backend.events[0].fields.notes, original.fields.notes)
            XCTAssertEqual(backend.events[0].details, original.details)
            XCTAssertEqual(call(broker, "commit_rollback", ["preview": inverse]), restored); XCTAssertEqual(backend.writeCount, 2)
            XCTAssertEqual(try state.execution(try XCTUnwrap(result["result"]["nonce"].string))?.payload, source.payload)
            XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "2")
            try state.verifyAudit()
        }
    }
    func testNoChangeAndUnsupportedSourceStylesOrTemporalMixingFailBeforeIntent() throws {
        let state = try state(), backend = try fixture(), broker = Broker(state: state, backend: backend), eventID = try id(broker)
        XCTAssertEqual(draft(broker, id: eventID, dateFields: dates("2026-10-25", "2026-11-03"))["error"]["code"], .string("no_change"))
        for mix: [String: JSON] in [["start": .string("2026-10-26T00:00:00Z")], ["end": .string("2026-11-02T00:00:00Z")], ["time_zone": .null], ["all_day": .bool(true)], ["recurrence": .null]] { XCTAssertNotEqual(draft(broker, id: eventID, metadata: mix)["error"], .null) }
        XCTAssertEqual(draft(broker, id: eventID, metadata: ["location": .string("Different structured place")])["error"]["code"], .string("unsupported_location"))
        backend.events[0].fields.end = "2026-11-02T23:59:59.500Z"
        XCTAssertEqual(draft(broker, id: eventID)["error"]["code"], .string("unsupported_all_day"))
        backend.events[0].fields.timeZone = "Europe/London"
        XCTAssertEqual(draft(broker, id: eventID)["error"]["code"], .string("unsupported_all_day"))
        XCTAssertEqual(backend.writeCount, 0); XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "0")
    }
    func testProviderExtraDayWrongStartZoneAndMetadataBecomeUnknownAndReplayOnce() throws {
        let unexpectedAlarm = try EventAlert(json: .object(["relative_minutes": .int(1)])).rawAlarm
        let corruptions: [(inout EventRecord, AllDayInterval) -> Void] = [
            { $0.fields.end = iso($1.endExclusive.addingTimeInterval(86400 - 1)) },
            { $0.fields.end = iso($1.writeEnd.addingTimeInterval(0.5)) },
            { $0.fields.start = iso($1.start.addingTimeInterval(1)) },
            { event, _ in event.fields.timeZone = "Europe/London" },
            { event, _ in event.fields.notes = "Unexpected" },
            { event, _ in var details = event.details.object!; details["alarms"] = .array([unexpectedAlarm]); event.details = .object(details) }
        ]
        for corrupt in corruptions {
            let state = try state(), backend = AllDayProbeBackend(), broker = Broker(state: state, backend: backend)
            backend.corrupt = corrupt
            let response = draft(broker), result = commit(broker, response)
            XCTAssertEqual(result["result"]["state"], .string("unknown"), "\(result)")
            XCTAssertEqual(commit(broker, response), result); XCTAssertEqual(backend.base.writeCount, 1)
            let blocked = draft(broker)
            XCTAssertEqual(commit(broker, blocked)["error"]["code"], .string("unresolved_write"))
        }
    }
    func testProjectionRacesAndSlowProviderExpiryPreservePreclaimAndUnknownBoundaries() throws {
        do {
            let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend), response = draft(broker)
            backend.allDayProjectionZone = "UTC"
            XCTAssertEqual(commit(broker, response)["error"]["code"], .string("stale_timezone"))
            XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "0")
        }
        for after in [false, true] {
            let state = try state(), backend = AllDayProbeBackend(), broker = Broker(state: state, backend: backend), response = draft(broker)
            if after { backend.afterWrite = { backend.base.allDayProjectionZone = "UTC" } }
            else { backend.beforeWrite = { backend.base.allDayProjectionZone = "UTC" } }
            XCTAssertEqual(commit(broker, response)["result"]["state"], .string("unknown"))
            XCTAssertEqual(backend.base.writeCount, after ? 1 : 0)
            XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "1")
        }
        let state = try state(), clock = AllDayClock(), base = try fixture(), backend = AllDayProbeBackend(base), broker = Broker(state: state, backend: backend, now: { clock.value })
        let response = draft(broker, id: try id(broker))
        backend.onGet = { clock.value = clock.value.addingTimeInterval(601) }
        XCTAssertEqual(commit(broker, response, action: "modify")["error"]["code"], .string("preview_expired"))
        XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "0")
    }
    func testAuthenticTemporalTamperingAndCrossRoutesRejectBeforeIntent() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend), response = draft(broker), preview = response["result"]["preview"]
        for variant in 0..<8 {
            var body = try XCTUnwrap(preview["envelope"].object), temporal = try XCTUnwrap(body["all_day"]?.object), after = try XCTUnwrap(body["after"]?.object)
            switch variant {
            case 0: temporal["write_end"] = .string("exclusive_midnight")
            case 1: temporal["readback_ends"] = .array([.string("inclusive_last_second")])
            case 2: temporal["before"] = dates()
            case 3: temporal["after"] = dates("2026-10-26", "2026-11-03")
            case 4: after["end"] = .string("2026-11-02T00:00:00.000Z")
            case 5: after["time_zone"] = .string("Europe/London")
            case 6: body["scope"] = .string("series")
            default: after["recurrence"] = .object(["frequency": .string("daily")])
            }
            body["all_day"] = .object(temporal); body["after"] = .object(after)
            XCTAssertNotEqual(call(broker, "commit_create", ["preview": try sign(.object(body), state: state)])["error"], .null)
        }
        for operation in ["commit_modify", "commit_rollback", "commit_series_modify", "commit_future_modify", "commit_future_delete", "commit_future_restore"] { XCTAssertNotEqual(call(broker, operation, ["preview": preview])["error"], .null) }
        XCTAssertEqual(backend.writeCount, 0); XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "0")
    }

    private func legacyEnvelope(_ broker: Broker, after: EventFields, before: JSON = .null, rollback: Bool = false) throws -> JSON {
        var body = try XCTUnwrap(draft(broker)["result"]["preview"]["envelope"].object)
        body.removeValue(forKey: "all_day")
        body["version"] = .int(rollback ? 2 : 3); body["action"] = .string(before == .null ? "create" : "modify")
        body["before"] = before; body["after"] = after.json
        if rollback {
            body.removeValue(forKey: "recovery")
            body["rollback"] = .object(["selection_id": .string(UUID().uuidString), "source_change_ids": .array([.string(UUID().uuidString)]), "source_digest": .string(String(repeating: "a", count: 64)), "restoration": before == .null ? .object(["details": .object([:]), "availability": .string("busy")]) : .null, "alarm_restoration": .array([]), "limitations": .array([])])
        } else { body["recovery"] = broker.recoveryContract(action: before == .null ? "create" : "modify", before: before) }
        return .object(body)
    }
    func testLegacyIncidentNormalizationUnknownReplayAndUnclaimedCreateRejection() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
        let intent = try EventFields.merged(.object(["title": .string("Synthetic legacy interval"), "start": .string("2026-10-26T00:00:00Z"), "end": .string("2026-11-02T00:00:00Z"), "time_zone": .string("Europe/London"), "all_day": .bool(true)]), with: nil)
        let envelope = try legacyEnvelope(broker, after: intent), preview = try sign(envelope, state: state)
        XCTAssertEqual(call(broker, "commit_create", ["preview": preview])["error"]["code"], .string("fresh_preview_required"))
        XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "0")
        // Reproduce the historical provider convention: a midnight end is treated
        // as an included date and read back at that date's final second, floating.
        let nonce = try XCTUnwrap(envelope["nonce"].string), sequence = try state.claim(nonce: nonce, payload: envelope, now: Date())
        _ = try backend.apply(action: "create", calendarID: "synthetic-calendar", existing: nil, fields: intent)
        backend.events[0].fields.timeZone = nil
        backend.events[0].fields.end = "2026-11-02T23:59:59.000Z"
        XCTAssertNotEqual(backend.events[0].fields, intent.withoutAlerts)
        XCTAssertEqual(try AllDayInterval.observed(backend.events[0].fields, projectionTimeZone: "Europe/London").json, dates("2026-10-26", "2026-11-03"))
        let unknown: JSON = .object(["nonce": .string(nonce), "state": .string("unknown"), "action": .string("create"), "audit_sequence": .int(sequence)])
        try state.finish(nonce: nonce, state: "unknown", result: unknown, event: "write_unknown")
        let immutable = try state.execution(nonce)!
        XCTAssertEqual(call(broker, "commit_create", ["preview": preview])["result"], unknown)
        XCTAssertEqual(backend.writeCount, 1)
        XCTAssertEqual(commit(broker, draft(broker))["error"]["code"], .string("unresolved_write"))
        XCTAssertEqual(try state.execution(nonce)?.payload, immutable.payload); XCTAssertEqual(try state.execution(nonce)?.result, immutable.result)
        try state.verifyAudit()
    }
    func testLegacyAllDayStructuralRollbackAndNamedDeletionCannotClaim() throws {
        let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend)
        let fields = try EventFields.merged(.object(["title": .string("Named all-day"), "start": .string("2026-10-26T00:00:00Z"), "end": .string("2026-11-02T00:00:00Z"), "time_zone": .string("Europe/London"), "all_day": .bool(true)]), with: nil)
        let createEnvelope = try legacyEnvelope(broker, after: fields.withoutAlerts, rollback: true)
        XCTAssertEqual(call(broker, "commit_rollback", ["preview": try sign(createEnvelope, state: state)])["error"]["code"], .string("fresh_preview_required"))
        backend.events = [EventRecord(nativeID: "named-all-day", calendarNativeID: "synthetic-calendar", fields: fields)]
        let before = try broker.view(backend.events[0])
        var changed = fields.withoutAlerts; changed.end = "2026-11-01T00:00:00.000Z"
        XCTAssertEqual(call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("this"), "event_id": before["id"], "fields": .object(["end": .string(changed.end)])])["error"]["code"], .string("unsupported_all_day"))
        let modifyEnvelope = try legacyEnvelope(broker, after: changed, before: before, rollback: true)
        XCTAssertEqual(call(broker, "commit_rollback", ["preview": try sign(modifyEnvelope, state: state)])["error"]["code"], .string("fresh_preview_required"))
        let delete = call(broker, "preflight_change", ["action": .string("delete"), "scope": .string("this"), "event_id": before["id"]])
        XCTAssertEqual(delete["error"]["code"], .string("unsupported_restore"))
        var deletion = try XCTUnwrap(legacyEnvelope(broker, after: fields, before: before).object)
        deletion["action"] = .string("delete"); deletion["after"] = .null; deletion["recovery"] = broker.recoveryContract(action: "delete", before: before)
        XCTAssertEqual(call(broker, "commit_delete", ["preview": try sign(.object(deletion), state: state)])["error"]["code"], .string("unsupported_restore"))
        XCTAssertEqual(backend.writeCount, 0); XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "0")
        // Existing authenticated recovery nonces still replay their stored result
        // before this writer's new structural restriction, including an unknown.
        let deletionPayload = JSON.object(deletion), sourceNonce = try XCTUnwrap(deletionPayload["nonce"].string)
        _ = try state.claim(nonce: sourceNonce, payload: deletionPayload, now: Date())
        try state.finish(nonce: sourceNonce, state: "applied", result: .object(["nonce": .string(sourceNonce), "state": .string("applied"), "action": .string("delete"), "deleted": .bool(true)]), event: "write_applied")
        var replayBody = createEnvelope.object!, recovery = replayBody["rollback"]!.object!
        recovery["source_change_ids"] = .array([.string(sourceNonce)])
        recovery["source_digest"] = .string(try broker.sourceDigest(state.recoveryRows()))
        replayBody["rollback"] = .object(recovery)
        let replayEnvelope = JSON.object(replayBody), nonce = try XCTUnwrap(replayEnvelope["nonce"].string)
        _ = try state.claim(nonce: nonce, payload: replayEnvelope, now: Date())
        let unknown: JSON = .object(["nonce": .string(nonce), "state": .string("unknown"), "action": .string("create")])
        try state.finish(nonce: nonce, state: "unknown", result: unknown, event: "write_unknown")
        XCTAssertEqual(call(broker, "commit_rollback", ["preview": try sign(replayEnvelope, state: state)])["result"], unknown)
        XCTAssertEqual(backend.writeCount, 0)
    }
    func testRecoverySourceBoundariesStaleZoneAndMultipleSelectionRemainConservative() throws {
        let state = try state(), backend = try fixture(), broker = Broker(state: state, backend: backend), eventID = try id(broker)
        let ordinary = call(broker, "preflight_change", ["action": .string("modify"), "scope": .string("this"), "event_id": eventID, "fields": .object(["title": .string("Metadata before civil edit")])])
        let ordinaryResult = commit(broker, ordinary, action: "modify")
        XCTAssertEqual(ordinaryResult["result"]["state"], .string("applied"))
        let result = commit(broker, draft(broker, id: eventID), action: "modify")
        XCTAssertEqual(result["result"]["state"], .string("applied"))
        XCTAssertEqual(undoDraft(broker, ordinaryResult["result"]["nonce"])["error"]["code"], .string("rollback_all_day_boundary"))
        XCTAssertEqual(call(broker, "preflight_rollback", ["change_ids": .array([ordinaryResult["result"]["nonce"], result["result"]["nonce"]])])["error"]["code"], .string("invalid_selection"))
        backend.allDayProjectionZone = "UTC"
        XCTAssertEqual(undoDraft(broker, result["result"]["nonce"])["error"]["code"], .string("stale_timezone"))
        backend.allDayProjectionZone = "Europe/London"; backend.events[0].fields.notes = "External edit"
        XCTAssertEqual(undoDraft(broker, result["result"]["nonce"])["error"]["code"], .string("stale_rollback"))
        XCTAssertEqual(backend.writeCount, 2)
    }
    func testFloorFiveUpgradePreservesUnknownAndAllAuthoritativeBytesAndOldWriterRefuses() throws {
        let directory: URL, proof: [String: [[String]]], metadata: [[String]]
        let tables = ["executions", "execution_details", "execution_keys", "write_safety_claims", "audit", "legacy_audit_manifest", "legacy_audit_details", "identities", "recovery_links", "commit_observations", "commit_observation_clock"]
        do {
            let state = try state(), backend = SyntheticBackend(), broker = Broker(state: state, backend: backend); directory = state.directory
            let calendar = call(broker, "list_calendars")["result"]["calendars"].array!.first!["id"]
            let timed = call(broker, "preflight_change", ["action": .string("create"), "scope": .string("this"), "calendar_id": calendar, "fields": .object(["title": .string("Historical timed fixture"), "start": .string("2026-10-26T10:00:00Z"), "end": .string("2026-10-26T11:00:00Z")])])
            XCTAssertEqual(commit(broker, timed)["result"]["state"], .string("applied"))
            let legacyFields = try EventFields.merged(.object(["title": .string("Historical all-day fixture"), "start": .string("2026-10-26T00:00:00Z"), "end": .string("2026-11-02T00:00:00Z"), "all_day": .bool(true), "time_zone": .string("Europe/London")]), with: nil)
            let payload = try legacyEnvelope(broker, after: legacyFields), nonce = try XCTUnwrap(payload["nonce"].string)
            _ = try state.claim(nonce: nonce, payload: payload, now: Date())
            try state.finish(nonce: nonce, state: "unknown", result: .object(["nonce": .string(nonce), "state": .string("unknown")]), event: "write_unknown")
            try state.execute("UPDATE metadata SET value='5' WHERE key='recovery_storage_version'")
            proof = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try state.rows("SELECT * FROM " + $0 + " ORDER BY rowid")) })
            metadata = try state.rows("SELECT * FROM metadata WHERE key NOT IN ('recovery_storage_version','recovery_clock_highwater') ORDER BY key")
        }
        do {
            let state = try self.state(directory)
            XCTAssertEqual(try state.metadata("recovery_storage_version"), "7")
            for table in tables { XCTAssertEqual(try state.rows("SELECT * FROM " + table + " ORDER BY rowid"), proof[table]) }
            XCTAssertEqual(try state.rows("SELECT * FROM metadata WHERE key NOT IN ('recovery_storage_version','recovery_clock_highwater') ORDER BY key"), metadata)
            XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "2")
            XCTAssertEqual(try state.rows("SELECT count(*) FROM executions WHERE state='unknown'")[0][0], "1")
            XCTAssertEqual(try JSON.parse(Data(state.rows("SELECT payload FROM executions")[0][0].utf8))["storage_version"], .int(2))
            try state.verifyAudit()
        }
        let frozen = "/private/tmp/calendar-future-v6-freeze-37czotr3/CalendarHelper"
        guard FileManager.default.isExecutableFile(atPath: frozen) else { throw XCTSkip("Frozen floor-five helper unavailable") }
        XCTAssertEqual(digest(try Data(contentsOf: URL(fileURLWithPath: frozen))), "f23d1b9cb4d8413fd05bf70529c99b797742636427f9fba891ffc929f0740b5b")
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: frozen); process.arguments = ["--migrate-recovery", "--state-dir", directory.path]; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1); XCTAssertEqual(try JSON.parse(output.fileHandleForReading.readDataToEndOfFile())["error"]["code"], .string("state_version"))
        let state = try self.state(directory)
        for table in tables { XCTAssertEqual(try state.rows("SELECT * FROM " + table + " ORDER BY rowid"), proof[table]) }
        try state.verifyAudit()
    }
}
