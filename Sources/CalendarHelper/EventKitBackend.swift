import Foundation
import EventKit
import CoreLocation
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
    private func firstSeriesEvent(for selected: EventRecord) throws -> EKEvent {
        guard selected.recurring, !selected.detached, let occurrence = selected.occurrence,
              let first = store.calendarItem(withIdentifier: selected.nativeID) as? EKEvent,
              first.calendar.calendarIdentifier == selected.calendarNativeID, first.calendarItemIdentifier == selected.nativeID,
              first.hasRecurrenceRules, !first.isDetached, let firstDate = first.occurrenceDate,
              firstDate <= (try parseDate(occurrence)) else { throw CoreError("ambiguous_occurrence", "Current series first occurrence cannot be established") }
        return first
    }
    func firstSeriesOccurrence(for selected: EventRecord) throws -> EventRecord {
        try refresh(); return try record(firstSeriesEvent(for: selected))
    }
    func applySeriesFields(anchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?) throws -> EventRecord {
        try refresh()
        guard let calendar = store.calendar(withIdentifier: anchor.calendarNativeID), self.calendar(calendar).writable else { throw CoreError("read_only", "Calendar is no longer writable") }
        let event = try firstSeriesEvent(for: anchor)
        guard try record(event) == anchor, !event.hasAttendees, event.organizer == nil else { throw CoreError("stale_event", "Series anchor changed immediately before write") }
        if changedFields.contains("title"), fields.title != anchor.fields.title { event.title = fields.title }
        if changedFields.contains("notes"), fields.notes != anchor.fields.notes { event.notes = fields.notes }
        if changedFields.contains("location"), fields.location != anchor.fields.location { event.location = fields.location }
        if changedFields.contains("alerts") {
            if let restoredAlarms { event.alarms = try self.restoredAlarms(restoredAlarms) }
            else { guard let alerts = fields.alerts else { throw CoreError("invalid_fields", "Missing series alerts") }; event.alarms = try alerts.map { alert in
                if let at = alert.at { return EKAlarm(absoluteDate: try parseDate(at)) }
                return EKAlarm(relativeOffset: Double(alert.relativeMinutes!) * 60)
            } }
        }
        // Only default properties above are assigned; recurrence and dates remain
        // provider-owned. Starting at its authoritative first occurrence covers
        // this current pattern, without merging prior split segments.
        try store.save(event, span: .futureEvents, commit: true)
        let saved = try record(event) // Direct save-result identity provenance.
        try refresh()
        let verified = try record(firstSeriesEvent(for: saved))
        guard verified.nativeID == saved.nativeID, verified.calendarNativeID == anchor.calendarNativeID else { throw CoreError("verification_failed", "Saved current series identity is unavailable") }
        return verified
    }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? {
        try apply(action: action, calendarID: calendarID, existing: existing, fields: fields, alarmRestoration: nil)
    }
    func applyRestoringAlarms(calendarID: String, existing: EventRecord, fields: EventFields, alarms: JSON) throws -> EventRecord? {
        try apply(action: "modify", calendarID: calendarID, existing: existing, fields: fields, alarmRestoration: alarms)
    }
    private func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?, alarmRestoration: JSON?) throws -> EventRecord? {
        try refresh()
        guard let c = store.calendar(withIdentifier: calendarID), calendar(c).writable else { throw CoreError("read_only", "Calendar is no longer writable") }
        let e: EKEvent
        if let existing {
            e = try resolve(nativeID: existing.nativeID, calendarID: calendarID, occurrence: existing.occurrence, knownStart: parseDate(existing.fields.start))
            guard try record(e) == existing, !e.hasAttendees, e.organizer == nil else { throw CoreError("stale_event", "Event changed immediately before write") }
        } else { e = EKEvent(eventStore: store); e.calendar = c }
        if action == "delete" { try store.remove(e, span: .thisEvent, commit: true); return nil }
        guard let fields else { throw CoreError("invalid_fields", "Missing write fields") }
        guard existing == nil || fields.recurrence == nil else { throw CoreError("unsupported_scope", "Recurrence changes require unsupported series editing") }
        let (start, end, zone) = try fields.dates()
        if existing == nil || existing?.fields.title != fields.title { e.title = fields.title }
        if existing == nil || existing?.fields.timeZone != fields.timeZone { e.timeZone = zone }
        if existing == nil || existing?.fields.allDay != fields.allDay { e.isAllDay = fields.allDay }
        if existing == nil || existing?.fields.start != fields.start { e.startDate = start }
        if existing == nil || existing?.fields.end != fields.end { e.endDate = end }
        if existing == nil || existing?.fields.location != fields.location { e.location = fields.location }
        if existing == nil || existing?.fields.notes != fields.notes { e.notes = fields.notes }
        if let alarmRestoration { e.alarms = try restoredAlarms(alarmRestoration) }
        else if let alerts = fields.alerts {
            e.alarms = try alerts.map { alert in
                if let at = alert.at { return EKAlarm(absoluteDate: try parseDate(at)) }
                return EKAlarm(relativeOffset: Double(alert.relativeMinutes!) * 60)
            }
        }
        if let recurrence = fields.recurrence {
            let frequency: EKRecurrenceFrequency
            switch recurrence.frequency { case "daily": frequency = .daily; case "weekly": frequency = .weekly; case "monthly": frequency = .monthly; default: frequency = .yearly }
            let end: EKRecurrenceEnd?
            if let count = recurrence.count { end = EKRecurrenceEnd(occurrenceCount: count) }
            else if let until = recurrence.until { end = EKRecurrenceEnd(end: try parseDate(until)) }
            else { end = nil }
            let days = recurrence.daysOfWeek?.map { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0)!) }
            e.recurrenceRules = [EKRecurrenceRule(recurrenceWith: frequency, interval: recurrence.interval, daysOfTheWeek: days, daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)]
        }
        try store.save(e, span: fields.recurrence == nil ? .thisEvent : .futureEvents, commit: true)
        if fields.recurrence != nil {
            guard let first = store.calendarItem(withIdentifier: e.calendarItemIdentifier) as? EKEvent,
                  first.calendar.calendarIdentifier == calendarID, first.hasRecurrenceRules, !first.isDetached,
                  first.occurrenceDate != nil else { throw CoreError("verification_failed", "Created series first occurrence is unavailable") }
            return try record(first)
        }
        return try record(e) // Identity provenance only; broker re-fetches for verification.
    }
    func restore(calendarID: String, fields: EventFields, details: JSON, availability: String) throws -> EventRecord {
        try refresh()
        guard let c = store.calendar(withIdentifier: calendarID), calendar(c).writable else { throw CoreError("read_only", "Original calendar is no longer writable") }
        let e = EKEvent(eventStore: store), (start, end, zone) = try fields.dates()
        e.calendar = c; e.title = fields.title; e.timeZone = zone; e.isAllDay = fields.allDay
        e.startDate = start; e.endDate = end; e.location = fields.location; e.notes = fields.notes
        if let value = details["url"].string { guard let url = URL(string: value) else { throw CoreError("unsupported_restore", "Stored event URL is invalid") }; e.url = url }
        e.structuredLocation = try restoredLocation(details["structured_location"])
        e.alarms = try restoredAlarms(details["alarms"])
        switch availability {
        case "free": e.availability = .free
        case "busy": e.availability = .busy
        case "tentative": e.availability = .tentative
        case "unavailable": e.availability = .unavailable
        case "unknown": e.availability = .notSupported
        default: throw CoreError("unsupported_restore", "Unsupported retained availability")
        }
        try store.save(e, span: .thisEvent, commit: true)
        return try record(e)
    }
    private func restoredAlarms(_ values: JSON) throws -> [EKAlarm] {
        guard let values = values.array else { throw CoreError("unsupported_restore", "Retained alarms must be an array") }
        return try values.map { value in
            let alarm: EKAlarm
            if let absolute = value["absolute_date"].string { alarm = EKAlarm(absoluteDate: try parseDate(absolute)) }
            else { guard let offset = value["relative_offset"].string.flatMap(Double.init), offset.isFinite else { throw CoreError("unsupported_restore", "Invalid retained alarm offset") }; alarm = EKAlarm(relativeOffset: offset) }
            guard let raw = value["proximity"].integer, let proximity = EKAlarmProximity(rawValue: raw) else { throw CoreError("unsupported_restore", "Unsupported alarm proximity") }
            alarm.proximity = proximity; alarm.structuredLocation = try restoredLocation(value["structured_location"])
            guard let type = value["type"].integer, let alarmType = EKAlarmType(rawValue: type), alarmType == .display || alarmType == .audio else { throw CoreError("unsupported_restore", "Only display and audio alarms can be restored") }
            alarm.soundName = value["sound_name"].string
            return alarm
        }
    }
    private func restoredLocation(_ value: JSON) throws -> EKStructuredLocation? {
        if value == .null { return nil }
        guard value.object != nil, let radius = value["radius"].string.flatMap(Double.init), radius.isFinite, radius >= 0 else { throw CoreError("unsupported_restore", "Invalid retained structured location") }
        let location = EKStructuredLocation(title: value["title"].string ?? "")
        location.title = value["title"].string
        location.radius = radius
        if value["latitude"] != .null || value["longitude"] != .null {
            guard let latitude = value["latitude"].string.flatMap(Double.init), let longitude = value["longitude"].string.flatMap(Double.init), latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw CoreError("unsupported_restore", "Invalid retained geographic location") }
            location.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
        }
        return location
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
