// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import EventKit
import CoreLocation
import CalendarCore

/// Created lazily only for an explicitly selected live backend. No permission prompt.
final class EventKitBackend: CalendarBackend {
    func allDayProjectionTimeZone() throws -> String { NSTimeZone.default.identifier }
    func applyAllDay(calendarID: String, existing: EventRecord?, fields: EventFields, interval: AllDayInterval, restoredAlarms: JSON?) throws -> EventRecord {
        return try ProviderMutationAttempt.run { attempt in
            try refresh()
            guard let calendar = store.calendar(withIdentifier: calendarID), self.calendar(calendar).writable else { throw CoreError("read_only", "Calendar is no longer writable") }
            guard try allDayProjectionTimeZone() == interval.projectionTimeZone,
                  try AllDayInterval(interval.json, projectionTimeZone: interval.projectionTimeZone) == interval,
                  fields == interval.materialized(fields) else { throw CoreError("stale_timezone", "All-day projection changed before assignment") }
            let event: EKEvent
            if let existing {
                guard !existing.recurring, !existing.detached, existing.occurrence == nil, existing.fields.allDay, existing.fields.timeZone == nil else { throw CoreError("unsupported_all_day", "Civil-date writes require one floating all-day event") }
                event = try resolve(nativeID: existing.nativeID, calendarID: calendarID, occurrence: nil, knownStart: parseDate(existing.fields.start))
                guard try record(event) == existing, !event.hasAttendees, event.organizer == nil else { throw CoreError("stale_event", "All-day event changed immediately before write") }
            } else { event = EKEvent(eventStore: store); event.calendar = calendar }
            if existing == nil || existing?.fields.title != fields.title { event.title = fields.title }
            interval.assign(setAllDay: { event.isAllDay = $0 }, setTimeZone: { event.timeZone = $0 }, setStart: { event.startDate = $0 }, setEnd: { event.endDate = $0 })
            if existing == nil || existing?.fields.location != fields.location { event.location = fields.location }
            if existing == nil || existing?.fields.notes != fields.notes { event.notes = fields.notes }
            if let restoredAlarms { event.alarms = try self.restoredAlarms(restoredAlarms) }
            else if let alerts = fields.alerts {
                event.alarms = try alerts.map { alert in
                    if let at = alert.at { return EKAlarm(absoluteDate: try parseDate(at)) }
                    return EKAlarm(relativeOffset: Double(alert.relativeMinutes!) * 60)
                }
            }
            guard try allDayProjectionTimeZone() == interval.projectionTimeZone else { throw CoreError("stale_timezone", "All-day projection changed immediately before save") }
            try attempt.mutate { try store.save(event, span: .thisEvent, commit: true) }
            attempt.reading(.providerRefresh)
            return try record(event)
        }
    }
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
    private func prefixMaster(for retained: EventRecord) throws -> EventRecord {
        try FuturePattern.prefixMaster(record(firstSeriesEvent(for: retained)), retained: retained)
    }
    func removeFuture(selected: EventRecord, originalAnchor: EventRecord, boundaryNow: () -> Date) throws -> FutureRemovalResult {
        return try ProviderMutationAttempt.run { attempt in
            try refresh()
            guard let calendar = store.calendar(withIdentifier: selected.calendarNativeID), self.calendar(calendar).writable else { throw CoreError("read_only", "Calendar is no longer writable") }
            let event = try resolve(nativeID: selected.nativeID, calendarID: selected.calendarNativeID, occurrence: selected.occurrence, knownStart: parseDate(selected.fields.start)), first = try firstSeriesEvent(for: selected)
            guard try record(event) == selected, try record(first) == originalAnchor,
                  !event.hasAttendees, event.organizer == nil, !first.hasAttendees, first.organizer == nil else { throw CoreError("stale_event", "Termination boundary or first anchor changed immediately before removal") }
            _ = try FutureTerminationPattern.copyRecurrence(selected: selected, anchor: originalAnchor, now: boundaryNow())
            _ = try FuturePattern.boundary(selected, now: boundaryNow())
            try attempt.mutate { try store.remove(event, span: .futureEvents, commit: true) }
            attempt.reading(.providerRefresh)
            try refresh()
            attempt.reading(.providerPrefixRead)
            let past = originalAnchor.occurrence == selected.occurrence ? nil : try prefixMaster(for: originalAnchor)
            return FutureRemovalResult(pastAnchor: past)
        }
    }
    func restoreFutureTail(calendarID: String, originalSelected: EventRecord, expectedPrefix: EventRecord?, fields: EventFields, details: JSON, availability: String) throws -> EventRecord {
        return try ProviderMutationAttempt.run { attempt in
            guard !fields.allDay else { throw CoreError("unsupported_restore", "All-day independent-copy recovery is unsupported") }
            try refresh()
            guard let calendar = store.calendar(withIdentifier: calendarID), self.calendar(calendar).writable,
                  let recurrence = fields.recurrence else { throw CoreError("unsupported_restore", "The writable original calendar and exact retained recurrence are required") }
            let (start, end, zone) = try FutureTerminationPattern.validateRetainedFields(fields)
            let event = EKEvent(eventStore: store); event.calendar = calendar
            event.title = fields.title; event.startDate = start; event.endDate = end; event.timeZone = zone; event.isAllDay = fields.allDay
            event.notes = fields.notes; event.location = fields.location
            if let text = details["url"].string { guard let url = URL(string: text) else { throw CoreError("unsupported_restore", "Invalid retained URL") }; event.url = url }
            event.structuredLocation = try restoredLocation(details["structured_location"]); event.alarms = try restoredAlarms(details["alarms"])
            switch availability {
            case "free": event.availability = .free
            case "busy": event.availability = .busy
            case "tentative": event.availability = .tentative
            case "unavailable": event.availability = .unavailable
            case "unknown": event.availability = .notSupported
            default: throw CoreError("unsupported_restore", "Unsupported retained availability")
            }
            event.recurrenceRules = [try recurrenceRule(recurrence)]
            guard calendarID == originalSelected.calendarNativeID else { throw CoreError("stale_calendar", "Original calendar binding changed") }
            do {
                _ = try resolve(nativeID: originalSelected.nativeID, calendarID: calendarID, occurrence: originalSelected.occurrence, knownStart: parseDate(originalSelected.fields.start))
                throw CoreError("stale_rollback", "Original boundary reappeared immediately before independent creation")
            } catch let error as CoreError where error.code == "event_missing" { }
            if let expectedPrefix {
                guard try prefixMaster(for: expectedPrefix) == expectedPrefix else { throw CoreError("stale_rollback", "Original prefix changed immediately before independent creation") }
            }
            try attempt.mutate { try store.save(event, span: .futureEvents, commit: true) }
            attempt.reading(.providerRefresh)
            let saved = try record(event)
            try refresh()
            return try record(firstSeriesEvent(for: saved))
        }
    }
    private func recurrenceRule(_ recurrence: EventRecurrence) throws -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch recurrence.frequency { case "daily": frequency = .daily; case "weekly": frequency = .weekly; case "monthly": frequency = .monthly; default: frequency = .yearly }
        let end: EKRecurrenceEnd?
        if let count = recurrence.count { end = EKRecurrenceEnd(occurrenceCount: count) }
        else if let until = recurrence.until { end = EKRecurrenceEnd(end: try parseDate(until)) }
        else { end = nil }
        let days = recurrence.daysOfWeek?.map { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0)!) }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: recurrence.interval, daysOfTheWeek: days, daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
    }
    func applyFutureFields(selected: EventRecord, originalAnchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?, boundaryNow: () -> Date) throws -> FutureWriteResult {
        return try ProviderMutationAttempt.run { attempt in
            try refresh()
            guard let calendar = store.calendar(withIdentifier: selected.calendarNativeID), self.calendar(calendar).writable else { throw CoreError("read_only", "Calendar is no longer writable") }
            let event = try resolve(nativeID: selected.nativeID, calendarID: selected.calendarNativeID, occurrence: selected.occurrence, knownStart: parseDate(selected.fields.start))
            let first = try firstSeriesEvent(for: selected)
            guard try record(event) == selected, try record(first) == originalAnchor,
                  !event.hasAttendees, event.organizer == nil, !first.hasAttendees, first.organizer == nil else { throw CoreError("stale_event", "Future boundary or first anchor changed immediately before write") }
            _ = try FuturePattern.validate(selected: selected, anchor: originalAnchor, now: boundaryNow())
            if changedFields.contains("title"), fields.title != selected.fields.title { event.title = fields.title }
            if changedFields.contains("notes"), fields.notes != selected.fields.notes { event.notes = fields.notes }
            if changedFields.contains("location"), fields.location != selected.fields.location { event.location = fields.location }
            if changedFields.contains("alerts") {
                if let restoredAlarms { event.alarms = try self.restoredAlarms(restoredAlarms) }
                else {
                    guard let alerts = fields.alerts else { throw CoreError("invalid_fields", "Missing future alerts") }
                    event.alarms = try alerts.map { alert in
                        if let at = alert.at { return EKAlarm(absoluteDate: try parseDate(at)) }
                        return EKAlarm(relativeOffset: Double(alert.relativeMinutes!) * 60)
                    }
                }
            }
            // Only the exact selected instance is saved. EventKit owns any split and
            // recurrence termination bookkeeping; user structural fields are never set.
            _ = try FuturePattern.boundary(selected, now: boundaryNow())
            try attempt.mutate { try store.save(event, span: .futureEvents, commit: true) }
            attempt.reading(.providerRefresh)
            let saved = try record(event) // Direct-save provenance, before reset.
            try refresh()
            let boundary = try record(resolve(nativeID: saved.nativeID, calendarID: saved.calendarNativeID, occurrence: selected.occurrence, knownStart: parseDate(selected.fields.start)))
            let past: EventRecord?
            if originalAnchor.occurrence != selected.occurrence {
            attempt.reading(.providerPrefixRead)
                past = try prefixMaster(for: originalAnchor)
            } else { past = nil }
            return FutureWriteResult(boundary: boundary, pastAnchor: past)
        }
    }
    func applySeriesFields(anchor: EventRecord, fields: EventFields, changedFields: [String], restoredAlarms: JSON?) throws -> EventRecord {
        return try ProviderMutationAttempt.run { attempt in
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
            try attempt.mutate { try store.save(event, span: .futureEvents, commit: true) }
            attempt.reading(.providerRefresh)
            let saved = try record(event) // Direct save-result identity provenance.
            try refresh()
            let verified = try record(firstSeriesEvent(for: saved))
            guard verified.nativeID == saved.nativeID, verified.calendarNativeID == anchor.calendarNativeID else { throw CoreError("verification_failed", "Saved current series identity is unavailable") }
            return verified
        }
    }
    func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?) throws -> EventRecord? {
        try apply(action: action, calendarID: calendarID, existing: existing, fields: fields, alarmRestoration: nil)
    }
    func applyRestoringAlarms(calendarID: String, existing: EventRecord, fields: EventFields, alarms: JSON) throws -> EventRecord? {
        try apply(action: "modify", calendarID: calendarID, existing: existing, fields: fields, alarmRestoration: alarms)
    }
    private func apply(action: String, calendarID: String, existing: EventRecord?, fields: EventFields?, alarmRestoration: JSON?) throws -> EventRecord? {
        return try ProviderMutationAttempt.run { attempt in
            try refresh()
            guard let c = store.calendar(withIdentifier: calendarID), calendar(c).writable else { throw CoreError("read_only", "Calendar is no longer writable") }
            let e: EKEvent
            if let existing {
                e = try resolve(nativeID: existing.nativeID, calendarID: calendarID, occurrence: existing.occurrence, knownStart: parseDate(existing.fields.start))
                guard try record(e) == existing, !e.hasAttendees, e.organizer == nil else { throw CoreError("stale_event", "Event changed immediately before write") }
            } else { e = EKEvent(eventStore: store); e.calendar = c }
            if action == "delete" { try attempt.mutate { try store.remove(e, span: .thisEvent, commit: true) }; return nil }
            guard let fields else { throw CoreError("invalid_fields", "Missing write fields") }
            guard existing == nil || fields.recurrence == nil else { throw CoreError("unsupported_scope", "Recurrence changes require unsupported series editing") }
            let (start, end, zone) = try existing.map { try fields.dates(preserving: $0.fields) } ?? fields.dates()
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
            if let recurrence = fields.recurrence { e.recurrenceRules = [try recurrenceRule(recurrence)] }
            try attempt.mutate { try store.save(e, span: fields.recurrence == nil ? .thisEvent : .futureEvents, commit: true) }
            attempt.reading(.providerRefresh)
            if fields.recurrence != nil {
                guard let first = store.calendarItem(withIdentifier: e.calendarItemIdentifier) as? EKEvent,
                      first.calendar.calendarIdentifier == calendarID, first.hasRecurrenceRules, !first.isDetached,
                      first.occurrenceDate != nil else { throw CoreError("verification_failed", "Created series first occurrence is unavailable") }
                return try record(first)
            }
            return try record(e) // Identity provenance only; broker re-fetches for verification.
        }
    }
    func restore(calendarID: String, fields: EventFields, details: JSON, availability: String) throws -> EventRecord {
        return try ProviderMutationAttempt.run { attempt in
            guard !fields.allDay else { throw CoreError("unsupported_restore", "All-day copy recovery requires a separately supported civil-date contract") }
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
            try attempt.mutate { try store.save(e, span: .thisEvent, commit: true) }
            attempt.reading(.providerRefresh)
            return try record(e)
        }
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
            "alarms": try EventSnapshot.canonicalAlarms(.array(alarms)), "unsupported_external_alarm": .bool((e.alarms ?? []).contains { $0.type == .procedure || $0.type == .email }), "recurrence_rules": .array((e.recurrenceRules ?? []).map(recurrence)), "structured_location": location(e.structuredLocation),
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
