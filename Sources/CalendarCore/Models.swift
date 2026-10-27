// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit

public func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}
public func parseDate(_ text: String) throws -> Date {
    // Explicit offset is mandatory; local ambiguous/nonexistent wall times are never guessed.
    guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
        throw CoreError("invalid_date", "Use an ISO8601 timestamp with seconds and an explicit UTC offset")
    }
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = f.date(from: text)
    if date == nil { f.formatOptions = [.withInternetDateTime]; date = f.date(from: text) }
    guard let date else { throw CoreError("invalid_date", "Invalid ISO8601 timestamp") }
    let offset: Int
    if text.hasSuffix("Z") { offset = 0 }
    else {
        let suffix = String(text.suffix(6)), parts = suffix.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[0] <= 23, parts[1] <= 59 else { throw CoreError("invalid_date", "Invalid UTC offset") }
        offset = (suffix.first == "-" ? -1 : 1) * (parts[0] * 3600 + parts[1] * 60)
    }
    guard let fixed = TimeZone(secondsFromGMT: offset) else { throw CoreError("invalid_date", "Invalid UTC offset") }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = fixed
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let expected = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!)
    guard expected == String(text.prefix(19)) else { throw CoreError("invalid_date", "Invalid Gregorian date or local clock time") }
    return date
}
public func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

public struct EventFields: Equatable, Sendable {
    public var title: String, start: String, end: String
    public var timeZone: String?
    public var allDay: Bool
    public var location: String, notes: String
    public var alerts: [EventAlert]?
    public var recurrence: EventRecurrence?
    public init(title: String, start: String, end: String, timeZone: String?, allDay: Bool, location: String = "", notes: String = "", alerts: [EventAlert]? = nil, recurrence: EventRecurrence? = nil) {
        self.title = title; self.start = start; self.end = end; self.timeZone = timeZone
        self.allDay = allDay; self.location = location; self.notes = notes; self.alerts = alerts; self.recurrence = recurrence
    }
    public var json: JSON {
        var values: [String: JSON] = [
        "title": .string(title), "start": .string(start), "end": .string(end), "time_zone": .optional(timeZone),
        "all_day": .bool(allDay), "location": .string(location), "notes": .string(notes)
        ]
        if let alerts { values["alerts"] = .array(alerts.map(\.json)) }
        if let recurrence { values["recurrence"] = recurrence.json }
        return .object(values)
    }
    /// Observed fields keep the stable seven-field contract; intents live in details.
    public var withoutAlerts: EventFields { var copy = self; copy.alerts = nil; copy.recurrence = nil; return copy }
    public init(json: JSON) throws {
        let a = try Arguments(json, allowed: ["title", "start", "end", "time_zone", "all_day", "location", "notes", "alerts", "recurrence"], required: ["title", "start", "end", "time_zone", "all_day", "location", "notes"])
        guard let title = a.values["title"]?.string, let location = a.values["location"]?.string,
              let notes = a.values["notes"]?.string, let allDay = a.values["all_day"]?.boolean,
              a.values["time_zone"] == .null || a.values["time_zone"]?.string != nil else { throw CoreError("invalid_arguments", "Invalid event fields") }
        self.init(title: title, start: try a.string("start"), end: try a.string("end"), timeZone: a.values["time_zone"]?.string, allDay: allDay, location: location, notes: notes, alerts: try a.values["alerts"].map(EventAlert.parse), recurrence: try a.values["recurrence"].map(EventRecurrence.init(json:)))
    }
    private func validatedInstants() throws -> (Date, Date, TimeZone?) {
        let zone = timeZone.flatMap(TimeZone.init(identifier:))
        guard timeZone == nil || zone != nil else { throw CoreError("invalid_timezone", "Invalid IANA timezone") }
        let a = try parseDate(start), b = try parseDate(end)
        guard b > a, b.timeIntervalSince(a) <= 366 * 86_400,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 1000,
              notes.count <= 10_000, location.count <= 2000 else { throw CoreError("invalid_fields", "Invalid event duration or text length") }
        if let zone {
            // An explicit offset must agree with the selected zone at that instant.
            for (text, date) in [(start, a), (end, b)] {
                let offset: Int
                if text.hasSuffix("Z") { offset = 0 }
                else {
                    let suffix = String(text.suffix(6)); let sign = suffix.first == "-" ? -1 : 1
                    let numbers = suffix.dropFirst().split(separator: ":").compactMap { Int($0) }
                    guard numbers.count == 2, numbers[0] <= 23, numbers[1] <= 59 else { throw CoreError("invalid_date", "Invalid UTC offset") }
                    offset = sign * (numbers[0] * 3600 + numbers[1] * 60)
                }
                // Canonical UTC snapshots intentionally use Z; callers may submit UTC instants
                // for a named timezone. Nonzero local offsets must be zone-consistent.
                if !text.hasSuffix("Z") && offset != zone.secondsFromGMT(for: date) {
                    throw CoreError("invalid_date", "Timestamp UTC offset disagrees with the event timezone")
                }
            }
        }
        return (a, b, zone)
    }
    public func dates() throws -> (Date, Date, TimeZone?) {
        let (a, b, zone) = try validatedInstants()
        if allDay, let zone {
            var c = Calendar(identifier: .gregorian); c.timeZone = zone
            guard c.startOfDay(for: a) == a, c.startOfDay(for: b) == b else { throw CoreError("invalid_fields", "All-day endpoints must be local midnight; end is exclusive") }
        } else if allDay {
            throw CoreError("unsupported_timezone", "Editing all-day events with a nil timezone is unsupported")
        }
        try recurrence?.validate(start: a, zone: zone)
        return (a, b, zone)
    }
    /// A floating all-day snapshot can be edited only while its opaque temporal
    /// fields remain exact. No timezone or civil-midnight interpretation is added.
    public func dates(preserving existing: EventFields) throws -> (Date, Date, TimeZone?) {
        guard existing.allDay, existing.timeZone == nil else { return try dates() }
        guard allDay == existing.allDay, timeZone == existing.timeZone,
              start == existing.start, end == existing.end, recurrence == nil else {
            throw CoreError("unsupported_timezone", "Nil-timezone all-day edits must preserve exact start, end, timezone and all-day state")
        }
        return try validatedInstants()
    }
    public func normalized() throws -> EventFields {
        let (a, b, _) = try dates()
        return EventFields(title: title, start: iso(a), end: iso(b), timeZone: timeZone, allDay: allDay, location: location, notes: notes, alerts: alerts, recurrence: recurrence)
    }
    public static func merged(_ patch: JSON, with existing: EventFields?) throws -> EventFields {
        let allowed: Set<String> = ["title", "start", "end", "time_zone", "all_day", "location", "notes", "alerts", "recurrence"]
        let a = try Arguments(patch, allowed: allowed)
        guard existing == nil || a.values["recurrence"] == nil else { throw CoreError("unsupported_scope", "Existing recurrence rules cannot be changed; modify one occurrence's displayed fields") }
        guard !a.values.isEmpty else { throw CoreError("invalid_arguments", "At least one field is required") }
        var values = existing?.json.object ?? ["time_zone": .string("Europe/London"), "all_day": .bool(false), "location": .string(""), "notes": .string(""), "alerts": .array([])]
        values.merge(a.values) { _, new in new }
        if let existing, existing.timeZone == nil, values["time_zone"] != .null {
            throw CoreError("unsupported_timezone", "Existing nil timezone semantics must be preserved")
        }
        let fields = try EventFields(json: .object(values))
        if let existing, existing.allDay, existing.timeZone == nil {
            _ = try fields.dates(preserving: existing)
            return fields
        }
        return try fields.normalized()
    }
}

public struct CalendarRecord: Equatable {
    public let nativeID: String
    public let title: String, source: String
    public let writable: Bool, subscribed: Bool
    public init(nativeID: String, title: String, source: String, writable: Bool = true, subscribed: Bool = false) {
        self.nativeID = nativeID; self.title = title; self.source = source; self.writable = writable; self.subscribed = subscribed
    }
    public func view(id: String) -> JSON { .object(["id": .string(id), "title": .string(title), "source": .string(source), "writable": .bool(writable && !subscribed), "subscribed": .bool(subscribed)]) }
}

public struct EventRecord: Equatable {
    public var nativeID: String, calendarNativeID: String
    public var occurrence: String?
    public var fields: EventFields
    public var recurring: Bool, detached: Bool, hasAttendees: Bool, hasOrganizer: Bool
    public var availability: String, status: String
    /// Deterministic structured snapshot of every additional supported EventKit property.
    public var details: JSON
    public init(nativeID: String, calendarNativeID: String, occurrence: String? = nil, fields: EventFields, recurring: Bool = false, detached: Bool = false, hasAttendees: Bool = false, hasOrganizer: Bool = false, availability: String = "busy", status: String = "confirmed", details: JSON = .object([:])) {
        self.nativeID = nativeID; self.calendarNativeID = calendarNativeID; self.occurrence = occurrence; self.fields = fields.withoutAlerts
        self.recurring = recurring; self.detached = detached; self.hasAttendees = hasAttendees; self.hasOrganizer = hasOrganizer
        self.availability = availability; self.status = status; self.details = details
    }
    public func view(id: String, calendar: JSON) throws -> JSON {
        let body: JSON = .object(["id": .string(id), "calendar": calendar, "occurrence": .optional(occurrence), "fields": fields.json,
                                 "recurring": .bool(recurring), "detached": .bool(detached), "has_attendees": .bool(hasAttendees),
                                 "has_organizer": .bool(hasOrganizer), "availability": .string(availability), "status": .string(status), "details": try EventSnapshot.canonicalDetails(details)])
        var object = body.object!; object["fingerprint"] = .string(digest(try body.data())); return .object(object)
    }
}

public protocol CalendarBackend: AnyObject {
    func allDayProjectionTimeZone() throws -> String
    func applyAllDay(calendarID: String, existing: EventRecord?, fields: EventFields, interval: AllDayInterval, restoredAlarms: JSON?) throws -> EventRecord
    func removeFuture(selected: EventRecord, originalAnchor: EventRecord, boundaryNow: () -> Date) throws -> FutureRemovalResult
    func restoreFutureTail(calendarID: String, originalSelected: EventRecord, expectedPrefix: EventRecord?, fields: EventFields, details: JSON, availability: String) throws -> EventRecord
    func applyFutureFields(selected: EventRecord, originalAnchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?, boundaryNow: () -> Date) throws -> FutureWriteResult
    func firstSeriesOccurrence(for selected: EventRecord) throws -> EventRecord
    func applySeriesFields(anchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?) throws -> EventRecord
    func calendars() throws -> [CalendarRecord]
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord]
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord
    func restore(calendarID: String, fields: EventFields, details: JSON, availability: String) throws -> EventRecord
    func applyRestoringAlarms(calendarID: String, existing: EventRecord, fields: EventFields, alarms: JSON) throws -> EventRecord?
    /// Any error after entering this method is conservatively an unknown outcome.
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord?
}

public extension CalendarBackend {
    func allDayProjectionTimeZone() throws -> String { throw CoreError("unsupported_all_day", "Backend does not support civil-date projection") }
    func applyAllDay(calendarID: String, existing: EventRecord?, fields: EventFields, interval: AllDayInterval, restoredAlarms: JSON?) throws -> EventRecord { throw CoreError("unsupported_all_day", "Backend does not support civil-date writes") }
    func removeFuture(selected: EventRecord, originalAnchor: EventRecord, boundaryNow: () -> Date) throws -> FutureRemovalResult { throw CoreError("unsupported_scope", "Backend cannot terminate a future pattern") }
    func restoreFutureTail(calendarID: String, originalSelected: EventRecord, expectedPrefix: EventRecord?, fields: EventFields, details: JSON, availability: String) throws -> EventRecord { throw CoreError("unsupported_restore", "Backend cannot create an independent retained tail") }
    func applyFutureFields(selected: EventRecord, originalAnchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?, boundaryNow: () -> Date) throws -> FutureWriteResult { throw CoreError("unsupported_scope", "Backend cannot modify future pattern defaults") }
    func firstSeriesOccurrence(for selected: EventRecord) throws -> EventRecord { throw CoreError("unsupported_scope", "Backend cannot establish the current series first occurrence") }
    func applySeriesFields(anchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?) throws -> EventRecord { throw CoreError("unsupported_scope", "Backend cannot modify current series defaults") }
    func applyRestoringAlarms(calendarID: String, existing: EventRecord, fields: EventFields, alarms: JSON) throws -> EventRecord? {
        throw CoreError("unsupported_restore", "Backend cannot restore retained alarms")
    }
    func restore(calendarID: String, fields: EventFields, details: JSON, availability: String) throws -> EventRecord {
        throw CoreError("unsupported_restore", "Backend cannot restore retained event details")
    }
}

public final class SyntheticBackend: CalendarBackend {
    public var allDayProjectionZone = "Europe/London"
    public var allDayUsesExclusiveEnd = false
    public func allDayProjectionTimeZone() throws -> String { allDayProjectionZone }
    public func applyAllDay(calendarID: String, existing: EventRecord?, fields: EventFields, interval: AllDayInterval, restoredAlarms: JSON?) throws -> EventRecord {
        guard allDayProjectionZone == interval.projectionTimeZone, fields == interval.materialized(fields) else { throw CoreError("stale_timezone", "Synthetic projection or all-day assignment changed") }
        if let existing {
            guard try get(nativeID: existing.nativeID, calendarID: calendarID, occurrence: existing.occurrence, knownStart: parseDate(existing.fields.start)) == existing else { throw CoreError("stale_event", "Synthetic all-day target changed") }
        }
        var assigned = fields
        if allDayUsesExclusiveEnd { assigned.end = iso(interval.endExclusive) }
        let result: EventRecord?
        if let existing, let restoredAlarms { result = try applyRestoringAlarms(calendarID: calendarID, existing: existing, fields: assigned, alarms: restoredAlarms) }
        else { result = try apply(action: existing == nil ? "create" : "modify", calendarID: calendarID, existing: existing, fields: assigned) }
        guard let result else { throw CoreError("verification_failed", "Synthetic all-day save returned no identity") }; return result
    }
    public var calendarRecords: [CalendarRecord]
    public var events: [EventRecord]
    public private(set) var writeCount = 0
    public var throwAfterWrite = false
    public init(calendars: [CalendarRecord]? = nil, events: [EventRecord] = []) {
        calendarRecords = calendars ?? [CalendarRecord(nativeID: "synthetic-calendar", title: "Synthetic Calendar", source: "Synthetic")]; self.events = events
    }
    public func calendars() throws -> [CalendarRecord] { calendarRecords }
    public func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] {
        try events.filter { event in
            guard calendarIDs.contains(event.calendarNativeID) else { return false }
            let a = try parseDate(event.fields.start), b = try parseDate(event.fields.end)
            return a < end && b > start
        }
    }
    public func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord {
        let matches = events.filter { $0.nativeID == nativeID && $0.calendarNativeID == calendarID && $0.occurrence == occurrence }
        guard !matches.isEmpty else { throw CoreError("event_missing", "Event identity is missing; query again") }
        guard matches.count == 1 else { throw CoreError("identity_ambiguous", "Event identity is ambiguous; query again") }; return matches[0]
    }
    public func restore(calendarID: String, fields: EventFields, details: JSON, availability: String) throws -> EventRecord {
        writeCount += 1
        let event = EventRecord(nativeID: UUID().uuidString, calendarNativeID: calendarID, fields: fields.withoutAlerts, availability: availability, details: details)
        events.append(event)
        if throwAfterWrite { throw CoreError("synthetic_crash", "Synthetic injected post-write failure") }
        return event
    }
    public func applyRestoringAlarms(calendarID: String, existing: EventRecord, fields: EventFields, alarms: JSON) throws -> EventRecord? {
        _ = try apply(action: "modify", calendarID: calendarID, existing: existing, fields: fields.withoutAlerts)
        let index = events.firstIndex { $0.nativeID == existing.nativeID && $0.occurrence == existing.occurrence }!
        var details = events[index].details.object ?? [:]; details["alarms"] = alarms; events[index].details = .object(details)
        return events[index]
    }
    public func firstSeriesOccurrence(for selected: EventRecord) throws -> EventRecord {
        guard selected.recurring, !selected.detached, selected.occurrence != nil else { throw CoreError("unsupported_scope", "Select a non-detached recurring occurrence") }
        let candidates = events.filter { $0.nativeID == selected.nativeID && $0.calendarNativeID == selected.calendarNativeID && $0.recurring && !$0.detached && $0.occurrence != nil }
        guard let firstDate = candidates.compactMap(\.occurrence).min() else { throw CoreError("event_missing", "Series first occurrence is unavailable") }
        let first = candidates.filter { $0.occurrence == firstDate }
        guard first.count == 1 else { throw CoreError("identity_ambiguous", "Series first occurrence is ambiguous") }
        return first[0]
    }
    public func removeFuture(selected: EventRecord, originalAnchor: EventRecord, boundaryNow: () -> Date) throws -> FutureRemovalResult {
        guard try get(nativeID: selected.nativeID, calendarID: selected.calendarNativeID, occurrence: selected.occurrence, knownStart: parseDate(selected.fields.start)) == selected,
              try firstSeriesOccurrence(for: selected) == originalAnchor else { throw CoreError("stale_event", "Future boundary or first anchor changed") }
        let boundary = try FuturePattern.validate(selected: selected, anchor: originalAnchor, now: boundaryNow())
        _ = try FuturePattern.boundary(selected, now: boundaryNow())
        writeCount += 1
        events.removeAll { $0.nativeID == selected.nativeID && $0.calendarNativeID == selected.calendarNativeID && !$0.detached && ($0.occurrence.map { (try? parseDate($0)) ?? .distantPast } ?? .distantPast) >= boundary }
        if originalAnchor.occurrence != selected.occurrence {
            for index in events.indices where events[index].nativeID == selected.nativeID && !events[index].detached {
                var details = events[index].details.object!, rules = details["recurrence_rules"]!.array!, rule = rules[0].object!
                rule["end_date"] = .string(iso(boundary.addingTimeInterval(-0.001))); rule["occurrence_count"] = .int(0)
                rules[0] = .object(rule); details["recurrence_rules"] = .array(rules); events[index].details = .object(details)
            }
        }
        if throwAfterWrite { throw CoreError("synthetic_crash", "Synthetic injected post-remove failure") }
        let past = originalAnchor.occurrence == selected.occurrence ? nil : try FuturePattern.prefixMaster(firstSeriesOccurrence(for: originalAnchor), retained: originalAnchor)
        return FutureRemovalResult(pastAnchor: past)
    }
    public func restoreFutureTail(calendarID: String, originalSelected: EventRecord, expectedPrefix: EventRecord?, fields: EventFields, details: JSON, availability: String) throws -> EventRecord {
        guard let recurrence = fields.recurrence else { throw CoreError("unsupported_restore", "Retained tail recurrence is required") }
        _ = try FutureTerminationPattern.validateRetainedFields(fields)
        guard calendarID == originalSelected.calendarNativeID else { throw CoreError("stale_calendar", "Original calendar binding changed") }
        do {
            _ = try get(nativeID: originalSelected.nativeID, calendarID: calendarID, occurrence: originalSelected.occurrence, knownStart: parseDate(originalSelected.fields.start))
            throw CoreError("stale_rollback", "Original boundary reappeared before independent creation")
        } catch let error as CoreError where error.code == "event_missing" { }
        if let expectedPrefix {
            guard try FuturePattern.prefixMaster(firstSeriesOccurrence(for: expectedPrefix), retained: expectedPrefix) == expectedPrefix else { throw CoreError("stale_rollback", "Original prefix changed immediately before independent creation") }
        }
        writeCount += 1
        var snapshot = details.object!; snapshot["recurrence_rules"] = .array([recurrence.rawRule])
        let saved = EventRecord(nativeID: UUID().uuidString, calendarNativeID: calendarID, occurrence: fields.start, fields: fields, recurring: true, availability: availability, details: .object(snapshot))
        events.append(saved)
        if throwAfterWrite { throw CoreError("synthetic_crash", "Synthetic injected post-create failure") }
        return saved
    }
    public func applyFutureFields(selected: EventRecord, originalAnchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?, boundaryNow: () -> Date) throws -> FutureWriteResult {
        guard try get(nativeID: selected.nativeID, calendarID: selected.calendarNativeID, occurrence: selected.occurrence, knownStart: parseDate(selected.fields.start)) == selected,
              try firstSeriesOccurrence(for: selected) == originalAnchor else { throw CoreError("stale_event", "Future pattern changed before write") }
        let boundary = try FuturePattern.validate(selected: selected, anchor: originalAnchor, now: boundaryNow())
        // The final clock check is immediately before the synthetic provider mutation.
        _ = try FuturePattern.boundary(selected, now: boundaryNow())
        writeCount += 1
        let split = originalAnchor.occurrence != selected.occurrence
        let tailID = split ? UUID().uuidString : selected.nativeID
        for index in events.indices where events[index].nativeID == selected.nativeID && events[index].calendarNativeID == selected.calendarNativeID && events[index].recurring && !events[index].detached {
            guard let occurrence = events[index].occurrence else { continue }
            if try parseDate(occurrence) < boundary {
                if split {
                    var details = events[index].details.object!, rules = details["recurrence_rules"]!.array!, rule = rules[0].object!
                    rule["end_date"] = .string(iso(boundary.addingTimeInterval(-0.001))); rule["occurrence_count"] = .int(0)
                    rules[0] = .object(rule); details["recurrence_rules"] = .array(rules); events[index].details = .object(details)
                }
                continue
            }
            events[index].nativeID = tailID
            if changedFields.contains("title") { events[index].fields.title = fields.title }
            if changedFields.contains("notes") { events[index].fields.notes = fields.notes }
            if changedFields.contains("location") { events[index].fields.location = fields.location }
            if changedFields.contains("alerts") {
                var details = events[index].details.object ?? [:]
                details["alarms"] = restoredAlarms ?? .array((fields.alerts ?? []).map(\.rawAlarm)); events[index].details = .object(details)
            }
        }
        if throwAfterWrite { throw CoreError("synthetic_crash", "Synthetic injected post-write failure") }
        let saved = try get(nativeID: tailID, calendarID: selected.calendarNativeID, occurrence: selected.occurrence, knownStart: parseDate(selected.fields.start))
        let prefix = split ? try FuturePattern.prefixMaster(firstSeriesOccurrence(for: originalAnchor), retained: originalAnchor) : nil
        return FutureWriteResult(boundary: saved, pastAnchor: prefix)
    }
    public func applySeriesFields(anchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?) throws -> EventRecord {
        guard try firstSeriesOccurrence(for: anchor) == anchor else { throw CoreError("stale_event", "Series anchor changed before write") }
        writeCount += 1
        for index in events.indices where events[index].nativeID == anchor.nativeID && events[index].calendarNativeID == anchor.calendarNativeID && events[index].recurring && !events[index].detached {
            if changedFields.contains("title") { events[index].fields.title = fields.title }
            if changedFields.contains("notes") { events[index].fields.notes = fields.notes }
            if changedFields.contains("location") { events[index].fields.location = fields.location }
            if changedFields.contains("alerts") {
                var details = events[index].details.object ?? [:]
                details["alarms"] = restoredAlarms ?? .array((fields.alerts ?? []).map(\.rawAlarm)); events[index].details = .object(details)
            }
        }
        if throwAfterWrite { throw CoreError("synthetic_crash", "Synthetic injected post-write failure") }
        return try firstSeriesOccurrence(for: anchor)
    }
    public func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? {
        writeCount += 1
        let result: EventRecord?
        if action == "create", let fields {
            var details: [String: JSON] = fields.alerts.map { ["alarms": .array($0.map(\.rawAlarm))] } ?? [:]
            if let recurrence = fields.recurrence { details["recurrence_rules"] = .array([recurrence.rawRule]) }
            let event = EventRecord(nativeID: UUID().uuidString, calendarNativeID: calendarID, occurrence: fields.recurrence == nil ? nil : fields.start, fields: fields.withoutAlerts, recurring: fields.recurrence != nil, details: .object(details)); events.append(event); result = event
        } else {
            guard let existing, let index = events.firstIndex(where: { $0.nativeID == existing.nativeID && $0.occurrence == existing.occurrence }) else { throw CoreError("event_missing", "Event missing during write") }
            if action == "delete" { events.remove(at: index); result = nil }
            else { guard let fields else { throw CoreError("invalid_fields", "Missing fields") }; events[index].fields = fields.withoutAlerts; if let alerts = fields.alerts { var details = events[index].details.object ?? [:]; details["alarms"] = .array(alerts.map(\.rawAlarm)); events[index].details = .object(details) }; result = events[index] }
        }
        if throwAfterWrite { throw CoreError("synthetic_crash", "Synthetic injected post-write failure") }; return result
    }
}
