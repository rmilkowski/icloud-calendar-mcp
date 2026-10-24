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
    public init(title: String, start: String, end: String, timeZone: String?, allDay: Bool, location: String = "", notes: String = "") {
        self.title = title; self.start = start; self.end = end; self.timeZone = timeZone
        self.allDay = allDay; self.location = location; self.notes = notes
    }
    public var json: JSON { .object([
        "title": .string(title), "start": .string(start), "end": .string(end), "time_zone": .optional(timeZone),
        "all_day": .bool(allDay), "location": .string(location), "notes": .string(notes)
    ]) }
    public init(json: JSON) throws {
        let a = try Arguments(json, allowed: ["title", "start", "end", "time_zone", "all_day", "location", "notes"], required: ["title", "start", "end", "time_zone", "all_day", "location", "notes"])
        guard let title = a.values["title"]?.string, let location = a.values["location"]?.string,
              let notes = a.values["notes"]?.string, let allDay = a.values["all_day"]?.boolean,
              a.values["time_zone"] == .null || a.values["time_zone"]?.string != nil else { throw CoreError("invalid_arguments", "Invalid event fields") }
        self.init(title: title, start: try a.string("start"), end: try a.string("end"), timeZone: a.values["time_zone"]?.string, allDay: allDay, location: location, notes: notes)
    }
    public func dates() throws -> (Date, Date, TimeZone?) {
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
            if allDay {
                var c = Calendar(identifier: .gregorian); c.timeZone = zone
                guard c.startOfDay(for: a) == a, c.startOfDay(for: b) == b else { throw CoreError("invalid_fields", "All-day endpoints must be local midnight; end is exclusive") }
            }
        } else if allDay {
            throw CoreError("unsupported_timezone", "Editing all-day events with a nil timezone is unsupported")
        }
        return (a, b, zone)
    }
    public func normalized() throws -> EventFields {
        let (a, b, _) = try dates()
        return EventFields(title: title, start: iso(a), end: iso(b), timeZone: timeZone, allDay: allDay, location: location, notes: notes)
    }
    public static func merged(_ patch: JSON, with existing: EventFields?) throws -> EventFields {
        let allowed: Set<String> = ["title", "start", "end", "time_zone", "all_day", "location", "notes"]
        let a = try Arguments(patch, allowed: allowed)
        guard !a.values.isEmpty else { throw CoreError("invalid_arguments", "At least one field is required") }
        var values = existing?.json.object ?? ["time_zone": .string("Europe/London"), "all_day": .bool(false), "location": .string(""), "notes": .string("")]
        values.merge(a.values) { _, new in new }
        if let existing, existing.timeZone == nil, values["time_zone"] != .null {
            throw CoreError("unsupported_timezone", "Existing nil timezone semantics must be preserved")
        }
        return try EventFields(json: .object(values)).normalized()
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
        self.nativeID = nativeID; self.calendarNativeID = calendarNativeID; self.occurrence = occurrence; self.fields = fields
        self.recurring = recurring; self.detached = detached; self.hasAttendees = hasAttendees; self.hasOrganizer = hasOrganizer
        self.availability = availability; self.status = status; self.details = details
    }
    public func view(id: String, calendar: JSON) throws -> JSON {
        let body: JSON = .object(["id": .string(id), "calendar": calendar, "occurrence": .optional(occurrence), "fields": fields.json,
                                 "recurring": .bool(recurring), "detached": .bool(detached), "has_attendees": .bool(hasAttendees),
                                 "has_organizer": .bool(hasOrganizer), "availability": .string(availability), "status": .string(status), "details": details])
        var object = body.object!; object["fingerprint"] = .string(digest(try body.data())); return .object(object)
    }
}

public protocol CalendarBackend: AnyObject {
    func calendars() throws -> [CalendarRecord]
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord]
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord
    func restore(calendarID: String, fields: EventFields, details: JSON, availability: String) throws -> EventRecord
    /// Any error after entering this method is conservatively an unknown outcome.
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord?
}

public extension CalendarBackend {
    func restore(calendarID: String, fields: EventFields, details: JSON, availability: String) throws -> EventRecord {
        throw CoreError("unsupported_restore", "Backend cannot restore retained event details")
    }
}

public final class SyntheticBackend: CalendarBackend {
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
        let event = EventRecord(nativeID: UUID().uuidString, calendarNativeID: calendarID, fields: fields, availability: availability, details: details)
        events.append(event)
        if throwAfterWrite { throw CoreError("synthetic_crash", "Synthetic injected post-write failure") }
        return event
    }
    public func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? {
        writeCount += 1
        let result: EventRecord?
        if action == "create", let fields {
            let event = EventRecord(nativeID: UUID().uuidString, calendarNativeID: calendarID, fields: fields); events.append(event); result = event
        } else {
            guard let existing, let index = events.firstIndex(where: { $0.nativeID == existing.nativeID && $0.occurrence == existing.occurrence }) else { throw CoreError("event_missing", "Event missing during write") }
            if action == "delete" { events.remove(at: index); result = nil }
            else { guard let fields else { throw CoreError("invalid_fields", "Missing fields") }; events[index].fields = fields; result = events[index] }
        }
        if throwAfterWrite { throw CoreError("synthetic_crash", "Synthetic injected post-write failure") }; return result
    }
}
