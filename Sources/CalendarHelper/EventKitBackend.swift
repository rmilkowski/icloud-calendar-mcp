import Foundation
import EventKit
import CalendarCore

/// Created lazily only for an explicitly selected live backend. No permission prompt.
final class EventKitBackend: CalendarBackend {
    private lazy var store = EKEventStore()
    private func refresh() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CoreError("calendar_access_required", "Full calendar access is required; run the bundled --authorize command explicitly locally")
        }
        store.reset()
    }
    private func calendar(_ c: EKCalendar) -> CalendarRecord {
        CalendarRecord(nativeID: c.calendarIdentifier, title: c.title, source: c.source.title, writable: c.allowsContentModifications && !c.isSubscribed, subscribed: c.isSubscribed)
    }
    func calendars() throws -> [CalendarRecord] { try refresh(); return store.calendars(for: .event).map(calendar) }
    func query(start: Date, end: Date, calendarIDs: [String]) throws -> [EventRecord] {
        try refresh()
        let selected = try calendarIDs.map { id -> EKCalendar in
            guard let c = store.calendar(withIdentifier: id) else { throw CoreError("calendar_missing", "Calendar identity unavailable") }; return c
        }
        return try store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: selected)).map(record)
    }
    private func resolve(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EKEvent {
        guard let c = store.calendar(withIdentifier: calendarID) else { throw CoreError("calendar_missing", "Calendar unavailable") }
        if occurrence == nil {
            guard let e = store.calendarItem(withIdentifier: nativeID) as? EKEvent,
                  e.calendar.calendarIdentifier == calendarID, !e.hasRecurrenceRules, !e.isDetached else { throw CoreError("event_missing", "Event no longer resolves; query again") }
            return e
        }
        // Use the previously observed actual start, not occurrenceDate (which remains
        // the original occurrence date even when a detached event moves weeks away).
        let found = store.events(matching: store.predicateForEvents(withStart: knownStart.addingTimeInterval(-3 * 86400), end: knownStart.addingTimeInterval(3 * 86400), calendars: [c]))
            .filter { $0.calendarItemIdentifier == nativeID && $0.occurrenceDate.map(iso) == occurrence }
        guard !found.isEmpty else { throw CoreError("event_missing", "Occurrence no longer resolves in its observed window; query again") }
        guard found.count == 1 else { throw CoreError("identity_ambiguous", "Occurrence identity is ambiguous; query again") }
        return found[0]
    }
    func get(nativeID: String, calendarID: String, occurrence: String?, knownStart: Date) throws -> EventRecord {
        try refresh(); return try record(resolve(nativeID: nativeID, calendarID: calendarID, occurrence: occurrence, knownStart: knownStart))
    }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? {
        try refresh()
        guard let c = store.calendar(withIdentifier: calendarID), calendar(c).writable else { throw CoreError("read_only", "Calendar is no longer writable") }
        let e: EKEvent
        if let existing {
            e = try resolve(nativeID: existing.nativeID, calendarID: calendarID, occurrence: existing.occurrence, knownStart: parseDate(existing.fields.start))
            guard try record(e) == existing, !e.hasAttendees, e.organizer == nil else { throw CoreError("stale_event", "Event changed immediately before write") }
        } else { e = EKEvent(eventStore: store); e.calendar = c }
        if action == "delete" { try store.remove(e, span: .thisEvent, commit: true); return nil }
        guard let fields else { throw CoreError("invalid_fields", "Missing write fields") }
        let (start, end, zone) = try fields.dates()
        if existing == nil || existing?.fields.title != fields.title { e.title = fields.title }
        if existing == nil || existing?.fields.timeZone != fields.timeZone { e.timeZone = zone }
        if existing == nil || existing?.fields.allDay != fields.allDay { e.isAllDay = fields.allDay }
        if existing == nil || existing?.fields.start != fields.start { e.startDate = start }
        if existing == nil || existing?.fields.end != fields.end { e.endDate = end }
        if existing == nil || existing?.fields.location != fields.location { e.location = fields.location }
        if existing == nil || existing?.fields.notes != fields.notes { e.notes = fields.notes }
        try store.save(e, span: .thisEvent, commit: true)
        return try record(e) // Identity provenance only; broker re-fetches for verification.
    }
    private func location(_ l: EKStructuredLocation?) -> JSON {
        guard let l else { return .null }
        var values: [String: JSON] = ["title": .optional(l.title), "radius": .string(String(l.radius))]
        if let g = l.geoLocation { values["latitude"] = .string(String(g.coordinate.latitude)); values["longitude"] = .string(String(g.coordinate.longitude)) }
        return .object(values)
    }
    private func recurrence(_ r: EKRecurrenceRule) -> JSON {
        func numbers(_ values: [NSNumber]?) -> JSON { .array((values ?? []).map { .int($0.intValue) }) }
        return .object(["calendar_identifier": .string(r.calendarIdentifier), "frequency": .int(r.frequency.rawValue), "interval": .int(r.interval), "first_day": .int(r.firstDayOfTheWeek),
            "days_of_week": .array((r.daysOfTheWeek ?? []).map { .object(["day": .int($0.dayOfTheWeek.rawValue), "week": .int($0.weekNumber)]) }),
            "days_of_month": numbers(r.daysOfTheMonth), "days_of_year": numbers(r.daysOfTheYear), "weeks_of_year": numbers(r.weeksOfTheYear), "months_of_year": numbers(r.monthsOfTheYear), "set_positions": numbers(r.setPositions),
            "end_date": .optional(r.recurrenceEnd?.endDate.map(iso)), "occurrence_count": r.recurrenceEnd.map { .int($0.occurrenceCount) } ?? .null])
    }
    private func record(_ e: EKEvent) throws -> EventRecord {
        guard let start = e.startDate, let end = e.endDate, let c = e.calendar else { throw CoreError("unsupported_event", "Incomplete event snapshot") }
        let alarms: [JSON] = (e.alarms ?? []).map { .object([
            "absolute_date": .optional($0.absoluteDate.map(iso)), "relative_offset": .string(String($0.relativeOffset)), "proximity": .int($0.proximity.rawValue), "structured_location": location($0.structuredLocation),
            "type": .int($0.type.rawValue), "email_address": .optional($0.emailAddress), "sound_name": .optional($0.soundName)]) }
        let details: JSON = .object(["url": .optional(e.url?.absoluteString), "external_id": .optional(e.calendarItemExternalIdentifier), "created": .optional(e.creationDate.map(iso)), "modified": .optional(e.lastModifiedDate.map(iso)),
            "alarms": .array(alarms), "unsupported_external_alarm": .bool((e.alarms ?? []).contains { $0.type == .procedure || $0.type == .email }), "recurrence_rules": .array((e.recurrenceRules ?? []).map(recurrence)), "structured_location": location(e.structuredLocation),
            "organizer": e.organizer.map { .object(["name": .optional($0.name), "url": .string($0.url.absoluteString)]) } ?? .null,
            "attendees": .array((e.attendees ?? []).map { .object(["name": .optional($0.name), "url": .string($0.url.absoluteString), "role": .int($0.participantRole.rawValue), "status": .int($0.participantStatus.rawValue), "type": .int($0.participantType.rawValue)]) })])
        let availability: String
        switch e.availability { case .free: availability = "free"; case .busy: availability = "busy"; case .tentative: availability = "tentative"; case .unavailable: availability = "unavailable"; default: availability = "unknown" }
        let status: String
        switch e.status { case .canceled: status = "cancelled"; case .confirmed: status = "confirmed"; case .tentative: status = "tentative"; default: status = "unknown" }
        return EventRecord(nativeID: e.calendarItemIdentifier, calendarNativeID: c.calendarIdentifier, occurrence: (e.hasRecurrenceRules || e.isDetached) ? e.occurrenceDate.map(iso) : nil,
            fields: EventFields(title: e.title ?? "", start: iso(start), end: iso(end), timeZone: e.timeZone?.identifier, allDay: e.isAllDay, location: e.location ?? "", notes: e.notes ?? ""),
            recurring: e.hasRecurrenceRules, detached: e.isDetached, hasAttendees: e.hasAttendees, hasOrganizer: e.organizer != nil, availability: availability, status: status, details: details)
    }
}
