import XCTest
import Foundation
import CryptoKit
@testable import CalendarCore

/// Synthetic snapshots only; never constructs EKEventStore or queries Calendar.
final class NilTimezoneAllDayTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }
    private func state() throws -> StateStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-nil-all-day-" + UUID().uuidString)
        directories.append(directory)
        let state = try StateStore(directory: directory)
        try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "a", count: 64))
        return state
    }
    private func call(_ broker: Broker, _ operation: String, _ arguments: [String: JSON] = [:]) -> JSON {
        broker.handle(.object(["op": .string(operation), "arguments": .object(arguments)]))
    }
    private func fields() -> EventFields {
        EventFields(title: "Synthetic all-day interval", start: "2026-10-18T23:00:00.000Z", end: "2026-11-02T23:59:59.000Z", timeZone: nil, allDay: true, location: "Original location", notes: "Original notes")
    }
    private func details() -> JSON {
        .object(["alarms": .array([.object(["absolute_date": .null, "relative_offset": .string("-300.0"), "proximity": .int(0), "structured_location": .null, "type": .int(1), "email_address": .null, "sound_name": .string("Synthetic sound")])]), "url": .string("https://example.invalid/fixture"), "structured_location": .null])
    }
    private func fixture() -> SyntheticBackend {
        SyntheticBackend(events: [EventRecord(nativeID: "nil-all-day", calendarNativeID: "synthetic-calendar", fields: fields(), details: details())])
    }
    private func views(_ broker: Broker, future: Bool = false) throws -> [JSON] {
        let response = call(broker, "query_events", ["start": .string(future ? "2026-12-01T00:00:00Z" : "2026-10-01T00:00:00Z"), "end": .string(future ? "2027-02-01T00:00:00Z" : "2026-12-01T00:00:00Z")])
        XCTAssertEqual(response["error"], .null)
        return try XCTUnwrap(response["result"]["events"].array)
    }
    private func draft(_ broker: Broker, id: JSON, fields: [String: JSON], scope: String = "this") -> JSON {
        call(broker, "preflight_change", ["action": .string("modify"), "scope": .string(scope), "event_id": id, "fields": .object(fields)])
    }
    private func inverse(_ broker: Broker, nonce: JSON) throws -> JSON {
        let response = call(broker, "preflight_rollback", ["change_ids": .array([nonce])])
        XCTAssertEqual(response["error"], .null, "\(response)")
        return try XCTUnwrap(response["result"]["steps"].array?.first?["preview"])
    }

    func testPreservedRawEndpointsRequireExactContextWithoutCivilDateInference() throws {
        let original = fields()
        XCTAssertThrowsError(try original.dates())
        for patch: JSON in [.object(["title": .string("Changed")]), .object(["notes": .string("Changed")]), .object(["location": .string("Changed")]), .object(["alerts": .array([])])] {
            let merged = try EventFields.merged(patch, with: original)
            XCTAssertEqual(merged.start, original.start)
            XCTAssertEqual(merged.end, original.end)
            XCTAssertNil(merged.timeZone)
            XCTAssertTrue(merged.allDay)
            let (start, end, zone) = try merged.dates(preserving: original)
            XCTAssertEqual(start, try parseDate(original.start))
            XCTAssertEqual(end, try parseDate(original.end))
            XCTAssertNil(zone)
            XCTAssertThrowsError(try merged.dates())
        }
        // Even an equivalent instant with different text cannot substitute for the
        // exact observed endpoint in the preserve-only contract.
        XCTAssertThrowsError(try EventFields.merged(.object(["start": .string("2026-10-19T00:00:00+01:00")]), with: original))
        XCTAssertThrowsError(try EventFields.merged(.object(["title": .string(" ")]), with: original))
        var midnightEnd = original; midnightEnd.end = "2026-11-02T00:00:00.000Z"
        XCTAssertEqual(try EventFields.merged(.object(["notes": .string("Changed")]), with: midnightEnd).end, midnightEnd.end)
    }

    func testOrdinaryMetadataAlertsReplayAndInversePreserveCompleteSnapshot() throws {
        for patch: [String: JSON] in [["title": .string("Changed title")], ["notes": .string("Changed notes")], ["location": .string("Changed location")], ["alerts": .array([.object(["relative_minutes": .int(-60)])])]] {
            let state = try state(), backend = fixture(), original = backend.events[0], broker = Broker(state: state, backend: backend)
            let id = try views(broker)[0]["id"], response = draft(broker, id: id, fields: patch)
            XCTAssertEqual(response["error"], .null, "\(response)")
            let preview = response["result"]["preview"], envelope = preview["envelope"]
            for key in ["start", "end", "time_zone", "all_day"] { XCTAssertEqual(envelope["after"][key], envelope["before"]["fields"][key]) }
            let applied = call(broker, "commit_modify", ["preview": preview])
            XCTAssertEqual(applied["result"]["state"], .string("applied"), "\(applied)")
            XCTAssertEqual(call(broker, "commit_modify", ["preview": preview]), applied)
            XCTAssertEqual(backend.writeCount, 1)
            XCTAssertEqual(try state.execution(try XCTUnwrap(envelope["nonce"].string))?.payload, envelope)
            XCTAssertEqual(backend.events[0].fields.start, original.fields.start)
            XCTAssertEqual(backend.events[0].fields.end, original.fields.end)
            XCTAssertNil(backend.events[0].fields.timeZone)
            if patch["alerts"] == nil { XCTAssertEqual(backend.events[0].details, original.details) }
            let rollback = try inverse(broker, nonce: applied["result"]["nonce"])
            let restored = call(broker, "commit_rollback", ["preview": rollback])
            XCTAssertEqual(restored["result"]["state"], .string("applied"), "\(restored)")
            XCTAssertEqual(backend.events[0], original)
            XCTAssertEqual(call(broker, "commit_rollback", ["preview": rollback]), restored)
            XCTAssertEqual(backend.writeCount, 2)
            XCTAssertEqual(try state.execution(try XCTUnwrap(envelope["nonce"].string))?.payload, envelope)
            try state.verifyAudit()
        }
    }

    func testStructuralEditsCreateDeleteAndAuthenticSubstitutionFailBeforeIntent() throws {
        let state = try state(), backend = fixture(), broker = Broker(state: state, backend: backend), id = try views(broker)[0]["id"]
        for patch: [String: JSON] in [["start": .string("2026-10-19T00:00:00Z")], ["end": .string("2026-11-01T00:00:00Z")], ["time_zone": .string("Europe/London")], ["all_day": .bool(false)], ["recurrence": .object(["frequency": .string("daily")])]] {
            XCTAssertNotEqual(draft(broker, id: id, fields: patch)["error"], .null)
        }
        XCTAssertEqual(call(broker, "preflight_change", ["action": .string("delete"), "scope": .string("this"), "event_id": id])["error"]["code"], .string("unsupported_timezone"))
        let calendar = call(broker, "list_calendars")["result"]["calendars"].array!.first!["id"]
        XCTAssertEqual(call(broker, "preflight_change", ["action": .string("create"), "scope": .string("this"), "calendar_id": calendar, "fields": fields().json])["error"]["code"], .string("unsupported_timezone"))
        let preview = draft(broker, id: id, fields: ["title": .string("Changed")])["result"]["preview"]
        var body = preview["envelope"].object!, after = body["after"]!.object!
        after["end"] = .string("2026-11-01T00:00:00.000Z"); body["after"] = .object(after)
        let envelope = JSON.object(body), key = SymmetricKey(data: Data(base64Encoded: try XCTUnwrap(state.metadata("signing_key")))!)
        let substituted: JSON = .object(["envelope": envelope, "authentication_tag": .string(Data(HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: key)).base64EncodedString())])
        XCTAssertEqual(call(broker, "commit_modify", ["preview": substituted])["error"]["code"], .string("fresh_preview_required"))
        XCTAssertEqual(backend.writeCount, 0)
        XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "0")
        XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims")[0][0], "0")
    }

    private func recurringFixture() throws -> SyntheticBackend {
        let rule = try EventRecurrence(json: .object(["frequency": .string("weekly")])).rawRule
        return SyntheticBackend(events: ["2027-01-01", "2027-01-08"].map { date in
            EventRecord(nativeID: "nil-all-day-pattern", calendarNativeID: "synthetic-calendar", occurrence: date + "T23:00:00.000Z", fields: EventFields(title: "Original default", start: date + "T23:00:00.000Z", end: date + "T23:30:00.000Z", timeZone: nil, allDay: true, notes: "Original notes"), recurring: true, details: .object(["alarms": details()["alarms"], "recurrence_rules": .array([rule]), "url": .null, "structured_location": .null]))
        })
    }
    func testCurrentAndFutureDefaultFieldsAndInversePreserveRawStructure() throws {
        for (scope, operation, rollbackOperation) in [("series", "commit_series_modify", "commit_series_rollback"), ("future", "commit_future_modify", "commit_future_rollback")] {
            let state = try state(), backend = try recurringFixture(), original = backend.events, broker = Broker(state: state, backend: backend)
            let response = draft(broker, id: try views(broker, future: true)[0]["id"], fields: ["title": .string("Changed default"), "notes": .string("Changed notes"), "alerts": .array([])], scope: scope)
            XCTAssertEqual(response["error"], .null, "\(response)")
            let applied = call(broker, operation, ["preview": response["result"]["preview"]])
            XCTAssertEqual(applied["result"]["state"], .string("applied"), "\(applied)")
            for (observed, old) in zip(backend.events, original) {
                XCTAssertEqual(observed.fields.start, old.fields.start); XCTAssertEqual(observed.fields.end, old.fields.end)
                XCTAssertNil(observed.fields.timeZone); XCTAssertTrue(observed.fields.allDay)
                XCTAssertEqual(observed.details["recurrence_rules"], old.details["recurrence_rules"])
            }
            let rollback = try inverse(broker, nonce: applied["result"]["nonce"])
            XCTAssertEqual(call(broker, rollbackOperation, ["preview": rollback])["result"]["state"], .string("applied"))
            XCTAssertEqual(backend.events, original)
            XCTAssertEqual(backend.writeCount, 2)
            try state.verifyAudit()
        }
    }
    func testFutureTerminationStillRejectsNilTimezoneBeforeIntent() throws {
        let state = try state(), backend = try recurringFixture(), broker = Broker(state: state, backend: backend), id = try views(broker, future: true)[0]["id"]
        let response = call(broker, "preflight_change", ["action": .string("delete"), "scope": .string("future"), "event_id": id, "cutoff": .object(["at": .string("2027-01-01T00:00:00Z")])])
        XCTAssertEqual(response["error"]["code"], .string("unsupported_timezone"), "\(response)")
        XCTAssertEqual(backend.writeCount, 0)
        XCTAssertEqual(try state.rows("SELECT count(*) FROM executions")[0][0], "0")
    }
}
