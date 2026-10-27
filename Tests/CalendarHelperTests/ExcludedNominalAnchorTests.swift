import XCTest
import Foundation
@testable import CalendarCore

/// A nominal master is provider-visible independently of expanded occurrences.
/// The excluded first date is never exposed by public get/query in this fixture.
private final class NominalMasterBackend: CalendarBackend {
    let originalID: String
    let nominalDate: String
    var master: EventRecord?
    let instances: SyntheticBackend
    var excluded = true
    var writeCount = 0
    var beforeRestore: (() -> Void)?
    var afterRestore: (() -> Void)?
    var afterMutation: (() -> Void)?
    var masterReads = 0
    var occurrenceReads = 0

    init(master: EventRecord, occurrences: [EventRecord]) {
        originalID = master.nativeID; nominalDate = master.occurrence!
        self.master = master; instances = SyntheticBackend(events: occurrences)
    }
    func calendars() throws -> [CalendarRecord] { try instances.calendars() }
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] {
        var result = try instances.query(start: start, end: end, calendarIDs: calendarIDs)
        if !excluded, let master, calendarIDs.contains(master.calendarNativeID),
           try parseDate(master.fields.start) < end, try parseDate(master.fields.end) > start { result.append(master) }
        return result
    }
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord {
        occurrenceReads += 1
        if !excluded, let master, master.nativeID == nativeID, master.calendarNativeID == calendarID, master.occurrence == occurrence { return master }
        return try instances.get(nativeID: nativeID, calendarID: calendarID, occurrence: occurrence, knownStart: knownStart)
    }
    func firstSeriesOccurrence(for selected: EventRecord) throws -> EventRecord {
        masterReads += 1
        if selected.nativeID == originalID {
            guard let master else { throw CoreError("event_missing", "Synthetic nominal master is missing") }
            return master
        }
        return try instances.firstSeriesOccurrence(for: selected)
    }
    private func prefix(_ retained: EventRecord) throws -> EventRecord {
        try FuturePattern.prefixMaster(firstSeriesOccurrence(for: retained), retained: retained)
    }
    private func provider<T>(_ operation: (SyntheticBackend) throws -> T) throws -> T {
        let provider = SyntheticBackend(events: (master.map { [$0] } ?? []) + instances.events)
        defer {
            writeCount += provider.writeCount
            master = provider.events.first { $0.nativeID == originalID && $0.occurrence == nominalDate }
            instances.events = provider.events.filter { !($0.nativeID == originalID && $0.occurrence == nominalDate) }
        }
        return try operation(provider)
    }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? {
        try provider { try $0.apply(action: action, calendarID: calendarID, existing: existing, fields: fields) }
    }
    func removeFuture(selected: EventRecord, originalAnchor: EventRecord, boundaryNow: () -> Date) throws -> FutureRemovalResult {
        let removed = try provider { try $0.removeFuture(selected: selected, originalAnchor: originalAnchor, boundaryNow: boundaryNow) }
        afterMutation?()
        return FutureRemovalResult(pastAnchor: removed.pastAnchor == nil ? nil : try prefix(originalAnchor))
    }
    func applyFutureFields(selected: EventRecord, originalAnchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?, boundaryNow: () -> Date) throws -> FutureWriteResult {
        let written = try provider { try $0.applyFutureFields(selected: selected, originalAnchor: originalAnchor, fields: fields, changedFields: changedFields, restoredAlarms: restoredAlarms, boundaryNow: boundaryNow) }
        afterMutation?()
        return FutureWriteResult(boundary: written.boundary, pastAnchor: written.pastAnchor == nil ? nil : try prefix(originalAnchor))
    }
    func restoreFutureTail(calendarID: String, originalSelected: EventRecord, expectedPrefix: EventRecord?, fields: EventFields, details: JSON, availability: String) throws -> EventRecord {
        beforeRestore?()
        if let expectedPrefix {
            guard try prefix(expectedPrefix) == expectedPrefix else { throw CoreError("stale_rollback", "Synthetic prefix changed before save") }
        }
        let saved = try provider { try $0.restoreFutureTail(calendarID: calendarID, originalSelected: originalSelected, expectedPrefix: expectedPrefix, fields: fields, details: details, availability: availability) }
        afterRestore?()
        return saved
    }
}

final class ExcludedNominalAnchorTests: XCTestCase {
    private var directories: [URL] = []
    private let nominal = "2026-10-04T09:00:00.000Z"
    private let boundary = "2026-11-01T10:00:00.000Z"
    private let now = try! parseDate("2026-10-25T09:00:00.000Z")
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at: directory) }; super.tearDown() }
    private func fixture() throws -> (StateStore, NominalMasterBackend, Broker) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-excluded-anchor-" + UUID().uuidString)
        directories.append(directory)
        let state = try StateStore(directory: directory)
        try state.configure(backendMode: "synthetic", credentialBinding: String(repeating: "e", count: 64))
        let rule = try EventRecurrence(json: .object(["frequency": .string("weekly")]))
        func event(_ date: String) throws -> EventRecord {
            EventRecord(nativeID: "synthetic-pattern", calendarNativeID: "synthetic-calendar", occurrence: date,
                        fields: EventFields(title: "Fixture title", start: date, end: iso(try parseDate(date).addingTimeInterval(3600)), timeZone: "Europe/London", allDay: false, location: "Fixture place", notes: "Fixture notes"), recurring: true,
                        details: .object(["recurrence_rules": .array([rule.rawRule]), "alarms": .array([]), "url": .string("https://example.invalid/fixture"), "structured_location": .null]))
        }
        let backend = try NominalMasterBackend(master: event(nominal), occurrences: [event("2026-10-25T10:00:00.000Z"), event(boundary), event("2026-11-08T10:00:00.000Z")])
        return (state, backend, Broker(state: state, backend: backend, now: { self.now }))
    }
    private func call(_ broker: Broker, _ op: String, _ arguments: [String: JSON] = [:]) -> JSON { broker.handle(.object(["op": .string(op), "arguments": .object(arguments)])) }
    private func selected(_ broker: Broker) throws -> JSON {
        let result = call(broker, "query_events", ["start": .string("2026-10-01T00:00:00Z"), "end": .string("2026-12-01T00:00:00Z")])
        return try XCTUnwrap(result["result"]["events"].array?.first { $0["occurrence"] == .string(boundary) })
    }
    private func draft(_ broker: Broker, modify: Bool = false) throws -> JSON {
        var arguments: [String: JSON] = ["action": .string(modify ? "modify" : "delete"), "scope": .string("future"), "event_id": try selected(broker)["id"]]
        if modify { arguments["fields"] = .object(["title": .string("Changed fixture")]) }
        else { arguments["cutoff"] = .object(["at": .string(boundary)]) }
        return try XCTUnwrap(call(broker, "preflight_change", arguments)["result"]["preview"].object.map(JSON.object))
    }
    private func commit(_ broker: Broker, _ preview: JSON, modify: Bool = false, restore: Bool = false) -> JSON {
        call(broker, restore ? "commit_future_restore" : (modify ? "commit_future_modify" : "commit_future_delete"), ["preview": preview])
    }
    private func inverse(_ broker: Broker, _ source: JSON) throws -> JSON {
        let plan = call(broker, "preflight_rollback", ["change_ids": .array([source])])
        return try XCTUnwrap(plan["result"]["steps"].array?.first?["preview"].object.map(JSON.object))
    }
    private func assertExcluded(_ backend: NominalMasterBackend, _ broker: Broker, id: JSON) throws {
        XCTAssertThrowsError(try backend.get(nativeID: backend.originalID, calendarID: "synthetic-calendar", occurrence: nominal, knownStart: parseDate(nominal)))
        XCTAssertEqual(call(broker, "get_event", ["event_id": id])["error"]["code"], .string("event_missing"))
        XCTAssertTrue(try backend.query(start: parseDate(nominal).addingTimeInterval(-3600), end: parseDate(nominal).addingTimeInterval(7200), calendarIDs: ["synthetic-calendar"]).isEmpty)
    }
    private func changeMaster(_ backend: NominalMasterBackend, mode: String) {
        switch mode {
        case "missing": backend.master = nil
        case "id": backend.master?.nativeID = "replacement-pattern"
        case "calendar": backend.master?.calendarNativeID = "replacement-calendar"
        case "occurrence": backend.master?.occurrence = "2026-10-11T09:00:00.000Z"
        case "start": backend.master?.fields.start = "2026-10-11T09:00:00.000Z"
        case "detached": backend.master?.detached = true
        case "nonrecurring": backend.master?.recurring = false
        case "rule":
            var details = backend.master!.details.object!, rule = details["recurrence_rules"]!.array![0].object!
            rule["interval"] = .int(2); details["recurrence_rules"] = .array([.object(rule)]); backend.master?.details = .object(details)
        default: backend.master?.fields.notes = "Unexpected fixture change"
        }
    }
    func testExcludedNominalMasterSupportsTerminationAndIndependentCopyWithoutOccurrenceFallback() throws {
        let (state, backend, broker) = try fixture(), preview = try draft(broker), id = preview["envelope"]["future"]["first_anchor"]["id"]
        try assertExcluded(backend, broker, id: id)
        let removed = commit(broker, preview)
        XCTAssertEqual(removed["result"]["state"], .string("applied")); XCTAssertEqual(backend.writeCount, 1)
        XCTAssertEqual(removed["result"]["past_anchor"]["id"], id)
        XCTAssertThrowsError(try backend.get(nativeID: backend.originalID, calendarID: "synthetic-calendar", occurrence: boundary, knownStart: parseDate(boundary)))
        let prefix = try XCTUnwrap(backend.master), restore = try inverse(broker, removed["result"]["nonce"])
        XCTAssertEqual(restore["envelope"]["rollback"]["restoration"]["past_anchor"], removed["result"]["past_anchor"])
        let result = commit(broker, restore, restore: true)
        XCTAssertEqual(result["result"]["state"], .string("applied")); XCTAssertEqual(backend.master, prefix)
        XCTAssertEqual(backend.writeCount, 2); XCTAssertEqual(commit(broker, restore, restore: true), result)
        XCTAssertEqual(commit(broker, preview), removed); XCTAssertEqual(backend.writeCount, 2)
        XCTAssertEqual(try state.rows("SELECT action FROM write_safety_claims"), [["delete"]])
        XCTAssertEqual(try state.rows("SELECT state FROM executions ORDER BY rowid"), [["applied"], ["applied"]])
        try assertExcluded(backend, broker, id: id); try state.verifyAudit()
    }
    func testFutureFieldSplitRetainsExcludedMasterAndInverseStillRequiresActualTailBoundary() throws {
        let (state, backend, broker) = try fixture(), preview = try draft(broker, modify: true)
        let id = preview["envelope"]["future"]["first_anchor"]["id"], before = try XCTUnwrap(backend.master)
        let result = commit(broker, preview, modify: true)
        XCTAssertEqual(result["result"]["state"], .string("applied")); XCTAssertEqual(backend.master?.fields, before.fields)
        XCTAssertEqual(result["result"]["past_anchor"]["id"], id); try assertExcluded(backend, broker, id: id)
        let restore = try inverse(broker, result["result"]["nonce"])
        let tail = try state.resolve(result["result"]["event"]["id"].string!, kind: "event")
        backend.instances.events.removeAll { $0.nativeID == tail.nativeID && $0.occurrence == boundary }
        XCTAssertNotEqual(call(broker, "commit_future_rollback", ["preview": restore])["error"], .null)
        XCTAssertEqual(backend.writeCount, 1); XCTAssertEqual(try state.rows("SELECT action FROM write_safety_claims"), [["modify"]])
    }
    private func assertMasterBeforeIntent(_ mode: String, modify: Bool) throws {
        let (state, backend, broker) = try fixture(), preview = try draft(broker, modify: modify)
        changeMaster(backend, mode: mode)
        XCTAssertNotEqual(commit(broker, preview, modify: modify)["error"], .null, mode)
        XCTAssertEqual(backend.writeCount, 0); XCTAssertTrue(try state.rows("SELECT nonce FROM executions").isEmpty)
        XCTAssertTrue(try state.rows("SELECT nonce FROM write_safety_claims").isEmpty)
    }

    private func assertMasterAfterMutation(_ mode: String, modify: Bool) throws {
        let (state, backend, broker) = try fixture(), preview = try draft(broker, modify: modify)
        backend.afterMutation = { self.changeMaster(backend, mode: mode) }
        let result = commit(broker, preview, modify: modify)
        XCTAssertEqual(result["result"]["state"], .string("unknown"), mode)
        XCTAssertEqual(commit(broker, preview, modify: modify), result); XCTAssertEqual(backend.writeCount, 1)
        XCTAssertEqual(try state.rows("SELECT count(*) FROM write_safety_claims"), [["1"]])
    }

    private func assertCopyMaster(_ mode: String, phase: String) throws {
        let (state, backend, broker) = try fixture(), deleted = commit(broker, try draft(broker))
        if phase == "review" {
            changeMaster(backend, mode: mode)
            XCTAssertNotEqual(call(broker, "preflight_rollback", ["change_ids": .array([deleted["result"]["nonce"]])])["error"], .null, mode)
        } else {
            let restore = try inverse(broker, deleted["result"]["nonce"])
            if phase == "commit" { changeMaster(backend, mode: mode) }
            if phase == "provider_entry" { backend.beforeRestore = { self.changeMaster(backend, mode: mode) } }
            if phase == "post_save" { backend.afterRestore = { self.changeMaster(backend, mode: mode) } }
            let result = commit(broker, restore, restore: true)
            if phase == "commit" { XCTAssertNotEqual(result["error"], .null, mode) }
            else {
                XCTAssertEqual(result["result"]["state"], .string("unknown"), mode)
                XCTAssertEqual(commit(broker, restore, restore: true), result)
            }
        }
        XCTAssertEqual(backend.writeCount, phase == "post_save" ? 2 : 1)
        XCTAssertEqual(try state.rows("SELECT count(*) FROM executions"), [[phase == "provider_entry" || phase == "post_save" ? "2" : "1"]])
        XCTAssertEqual(try state.rows("SELECT action FROM write_safety_claims"), [["delete"]])
    }

    func testMasterBeforeIntentDeleteMissing() throws { try assertMasterBeforeIntent("missing", modify: false) }
    func testMasterAfterMutationDeleteMissing() throws { try assertMasterAfterMutation("missing", modify: false) }
    func testMasterBeforeIntentDeleteId() throws { try assertMasterBeforeIntent("id", modify: false) }
    func testMasterAfterMutationDeleteId() throws { try assertMasterAfterMutation("id", modify: false) }
    func testMasterBeforeIntentDeleteCalendar() throws { try assertMasterBeforeIntent("calendar", modify: false) }
    func testMasterAfterMutationDeleteCalendar() throws { try assertMasterAfterMutation("calendar", modify: false) }
    func testMasterBeforeIntentDeleteOccurrence() throws { try assertMasterBeforeIntent("occurrence", modify: false) }
    func testMasterAfterMutationDeleteOccurrence() throws { try assertMasterAfterMutation("occurrence", modify: false) }
    func testMasterBeforeIntentDeleteStart() throws { try assertMasterBeforeIntent("start", modify: false) }
    func testMasterAfterMutationDeleteStart() throws { try assertMasterAfterMutation("start", modify: false) }
    func testMasterBeforeIntentDeleteDetached() throws { try assertMasterBeforeIntent("detached", modify: false) }
    func testMasterAfterMutationDeleteDetached() throws { try assertMasterAfterMutation("detached", modify: false) }
    func testMasterBeforeIntentDeleteNonrecurring() throws { try assertMasterBeforeIntent("nonrecurring", modify: false) }
    func testMasterAfterMutationDeleteNonrecurring() throws { try assertMasterAfterMutation("nonrecurring", modify: false) }
    func testMasterBeforeIntentDeleteRule() throws { try assertMasterBeforeIntent("rule", modify: false) }
    func testMasterAfterMutationDeleteRule() throws { try assertMasterAfterMutation("rule", modify: false) }
    func testMasterBeforeIntentDeleteFields() throws { try assertMasterBeforeIntent("fields", modify: false) }
    func testMasterAfterMutationDeleteFields() throws { try assertMasterAfterMutation("fields", modify: false) }
    func testMasterBeforeIntentModifyMissing() throws { try assertMasterBeforeIntent("missing", modify: true) }
    func testMasterAfterMutationModifyMissing() throws { try assertMasterAfterMutation("missing", modify: true) }
    func testMasterBeforeIntentModifyId() throws { try assertMasterBeforeIntent("id", modify: true) }
    func testMasterAfterMutationModifyId() throws { try assertMasterAfterMutation("id", modify: true) }
    func testMasterBeforeIntentModifyCalendar() throws { try assertMasterBeforeIntent("calendar", modify: true) }
    func testMasterAfterMutationModifyCalendar() throws { try assertMasterAfterMutation("calendar", modify: true) }
    func testMasterBeforeIntentModifyOccurrence() throws { try assertMasterBeforeIntent("occurrence", modify: true) }
    func testMasterAfterMutationModifyOccurrence() throws { try assertMasterAfterMutation("occurrence", modify: true) }
    func testMasterBeforeIntentModifyStart() throws { try assertMasterBeforeIntent("start", modify: true) }
    func testMasterAfterMutationModifyStart() throws { try assertMasterAfterMutation("start", modify: true) }
    func testMasterBeforeIntentModifyDetached() throws { try assertMasterBeforeIntent("detached", modify: true) }
    func testMasterAfterMutationModifyDetached() throws { try assertMasterAfterMutation("detached", modify: true) }
    func testMasterBeforeIntentModifyNonrecurring() throws { try assertMasterBeforeIntent("nonrecurring", modify: true) }
    func testMasterAfterMutationModifyNonrecurring() throws { try assertMasterAfterMutation("nonrecurring", modify: true) }
    func testMasterBeforeIntentModifyRule() throws { try assertMasterBeforeIntent("rule", modify: true) }
    func testMasterAfterMutationModifyRule() throws { try assertMasterAfterMutation("rule", modify: true) }
    func testMasterBeforeIntentModifyFields() throws { try assertMasterBeforeIntent("fields", modify: true) }
    func testMasterAfterMutationModifyFields() throws { try assertMasterAfterMutation("fields", modify: true) }
    func testCopyMasterReviewMissing() throws { try assertCopyMaster("missing", phase: "review") }
    func testCopyMasterReviewId() throws { try assertCopyMaster("id", phase: "review") }
    func testCopyMasterReviewCalendar() throws { try assertCopyMaster("calendar", phase: "review") }
    func testCopyMasterReviewOccurrence() throws { try assertCopyMaster("occurrence", phase: "review") }
    func testCopyMasterReviewStart() throws { try assertCopyMaster("start", phase: "review") }
    func testCopyMasterReviewRule() throws { try assertCopyMaster("rule", phase: "review") }
    func testCopyMasterReviewFields() throws { try assertCopyMaster("fields", phase: "review") }
    func testCopyMasterCommitMissing() throws { try assertCopyMaster("missing", phase: "commit") }
    func testCopyMasterCommitId() throws { try assertCopyMaster("id", phase: "commit") }
    func testCopyMasterCommitCalendar() throws { try assertCopyMaster("calendar", phase: "commit") }
    func testCopyMasterCommitOccurrence() throws { try assertCopyMaster("occurrence", phase: "commit") }
    func testCopyMasterCommitStart() throws { try assertCopyMaster("start", phase: "commit") }
    func testCopyMasterCommitRule() throws { try assertCopyMaster("rule", phase: "commit") }
    func testCopyMasterCommitFields() throws { try assertCopyMaster("fields", phase: "commit") }
    func testCopyMasterProviderEntryMissing() throws { try assertCopyMaster("missing", phase: "provider_entry") }
    func testCopyMasterProviderEntryId() throws { try assertCopyMaster("id", phase: "provider_entry") }
    func testCopyMasterProviderEntryCalendar() throws { try assertCopyMaster("calendar", phase: "provider_entry") }
    func testCopyMasterProviderEntryOccurrence() throws { try assertCopyMaster("occurrence", phase: "provider_entry") }
    func testCopyMasterProviderEntryStart() throws { try assertCopyMaster("start", phase: "provider_entry") }
    func testCopyMasterProviderEntryRule() throws { try assertCopyMaster("rule", phase: "provider_entry") }
    func testCopyMasterProviderEntryFields() throws { try assertCopyMaster("fields", phase: "provider_entry") }
    func testCopyMasterPostSaveMissing() throws { try assertCopyMaster("missing", phase: "post_save") }
    func testCopyMasterPostSaveId() throws { try assertCopyMaster("id", phase: "post_save") }
    func testCopyMasterPostSaveCalendar() throws { try assertCopyMaster("calendar", phase: "post_save") }
    func testCopyMasterPostSaveOccurrence() throws { try assertCopyMaster("occurrence", phase: "post_save") }
    func testCopyMasterPostSaveStart() throws { try assertCopyMaster("start", phase: "post_save") }
    func testCopyMasterPostSaveRule() throws { try assertCopyMaster("rule", phase: "post_save") }
    func testCopyMasterPostSaveFields() throws { try assertCopyMaster("fields", phase: "post_save") }
}
