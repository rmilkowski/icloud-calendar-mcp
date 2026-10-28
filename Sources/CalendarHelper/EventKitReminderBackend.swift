// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
@preconcurrency import EventKit
import CoreLocation
import CalendarCore

/// The callback only transfers ownership; EventKit properties are read by the caller.
private final class ReminderFetchedItems: @unchecked Sendable {
    let values: [EKReminder]
    init(_ values: [EKReminder]) { self.values = values }
}

/// Instantiated only by explicit native opt-in; authorization is checked before lazy store access.
final class EventKitReminderBackend: ReminderBackend {
    private lazy var store = EKEventStore()

    private func permission() throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw CoreError("reminders_access_required", "Separate full Reminders access is required; request it explicitly for the settled app")
        }
    }
    private func refresh() throws { try permission(); store.reset() }
    private func selectedList(_ id: String, writable: Bool = false) throws -> EKCalendar {
        guard let value = store.calendar(withIdentifier: id), value.allowedEntityTypes.contains(.reminder) else { throw CoreError("reminder_list_missing", "Reminder list no longer resolves") }
        if writable && (!value.allowsContentModifications || value.isSubscribed) { throw CoreError("read_only", "Reminder list is not writable") }
        return value
    }
    private func resolve(_ id: String, listID: String) throws -> EKReminder {
        _ = try selectedList(listID)
        guard let value = store.calendarItem(withIdentifier: id) as? EKReminder,
              value.calendar?.calendarIdentifier == listID else { throw CoreError("reminder_missing", "Reminder no longer resolves; query again") }
        return value
    }
    func lists() throws -> [ReminderListRecord] {
        try refresh()
        let values = store.calendars(for: .reminder)
        guard values.count <= 200 else { throw CoreError("reminder_limit", "More than 200 reminder lists cannot be represented") }
        return values.map { ReminderListRecord(nativeID: $0.calendarIdentifier, title: $0.title, source: $0.source.title,
                                               writable: $0.allowsContentModifications && !$0.isSubscribed) }
    }
    func query(listID: String) throws -> [ReminderRecord] {
        try refresh()
        let selected = try selectedList(listID)
        let gate = ReminderFetchGate<ReminderFetchedItems>()
        let identifier = store.fetchReminders(matching: store.predicateForReminders(in: [selected])) { values in
            if let values { gate.complete(.success(ReminderFetchedItems(values))) }
            else { gate.complete(.failure(CoreError("reminder_fetch_failed", "Reminder provider returned no fetch result"))) }
        }
        let fetched: ReminderFetchedItems
        do { fetched = try gate.wait() }
        catch { store.cancelFetchRequest(identifier); throw error }
        // Late callbacks never serialize or touch objects after timeout/reset.
        return try fetched.values.map(Self.record)
    }
    func get(nativeID: String, listID: String) throws -> ReminderRecord {
        try refresh(); return try Self.record(resolve(nativeID, listID: listID))
    }

    func apply(action: String, listID: String, existing: ReminderRecord?, fields: ReminderFields?, completed: Bool?, changedFields: [String], completionPolicy: String, completionDate: Date?, restoration: JSON?) throws -> ReminderWriteResult {
        try ProviderMutationAttempt.run { attempt in
            try refresh()
            let list = try selectedList(listID, writable: true)
            let value: EKReminder
            if let existing {
                value = try resolve(existing.nativeID, listID: listID)
                let current = try Self.record(value)
                guard current == existing else { throw CoreError("stale_event", "Reminder changed immediately before provider entry") }
                try ReminderWriteWitness.eligibility(current)
            } else {
                guard action == "create" else { throw CoreError("invalid_fields", "Existing reminder identity is required") }
                value = EKReminder(eventStore: store); value.calendar = list
            }
            if action == "delete" {
                guard existing != nil, changedFields.isEmpty, completionPolicy == "none" else { throw CoreError("invalid_fields", "Deletion requires one unchanged reminder") }
                try permission()
                try attempt.mutate { try store.remove(value, commit: true) }
                attempt.reading(.providerRefresh); try refresh()
                guard store.calendarItem(withIdentifier: existing!.nativeID) == nil else { throw CoreError("verification_failed", "Deleted reminder still resolves") }
                return ReminderWriteResult(record: nil, completionDate: nil)
            }
            guard let fields, let completed else { throw CoreError("invalid_fields", "Missing reminder assignment") }
            let mask = Set(changedFields)
            guard mask.isSubset(of: ["title", "notes", "priority", "start", "due", "alerts", "completed"]) else { throw CoreError("invalid_fields", "Unsupported reminder field") }
            if mask.contains("title") { value.title = fields.title }
            if mask.contains("notes") { value.notes = fields.notes }
            if mask.contains("priority") { value.priority = fields.priority }
            if mask.contains("start") { value.startDateComponents = try Self.assignment(fields.start, raw: restoration?["start_components"]) }
            if mask.contains("due") { value.dueDateComponents = try Self.assignment(fields.due, raw: restoration?["due_components"]) }
            if mask.contains("alerts") {
                if let restoration { value.alarms = try Self.restoreAlarms(restoration["alarms"]) }
                else {
                    guard let alerts = fields.alerts else { throw CoreError("invalid_fields", "Missing explicit reminder alerts") }
                    value.alarms = try alerts.map { try Self.displayAlarm($0.at) }
                }
            }
            if existing == nil, let restoration {
                guard restoration["recurrence_rules"].array?.isEmpty == true else { throw CoreError("unsupported_restore", "Recurring reminder restoration is unsupported") }
                value.location = restoration["location"].string
                if let text = restoration["url"].string {
                    guard let url = URL(string: text) else { throw CoreError("unsupported_restore", "Retained reminder URL cannot be restored") }
                    value.url = url
                }
                if let zone = restoration["item_time_zone"].string {
                    guard let parsed = TimeZone(identifier: zone) else { throw CoreError("unsupported_restore", "Retained reminder timezone cannot be restored") }
                    value.timeZone = parsed
                } else { value.timeZone = nil }
            }
            let chosen: Date?
            switch completionPolicy {
            case "preserve":
                guard let existing, completed == existing.completed else { throw CoreError("invalid_fields", "Reminder completion must be preserved") }
                chosen = try existing.exactCompletionDate()
            case "clear":
                guard !completed else { throw CoreError("invalid_fields", "Cleared reminder completion cannot be true") }
                value.isCompleted = false; value.completionDate = nil; chosen = nil
            case "restore":
                guard completed == (completionDate != nil), restoration != nil else { throw CoreError("unsupported_restore", "Exact retained completion is required") }
                value.isCompleted = completed; value.completionDate = completionDate; chosen = completionDate
            case "set_on_commit":
                guard action == "complete", completed, mask == ["completed"] else { throw CoreError("invalid_fields", "Completion policy requires completion action") }
                chosen = ReminderCompletionTime.onCommit(now: Date()); value.isCompleted = true; value.completionDate = chosen
            default: throw CoreError("invalid_fields", "Unsupported completion timestamp policy")
            }
            try permission()
            try attempt.mutate { try store.save(value, commit: true) }
            attempt.reading(.providerRefresh)
            // The save result is the sole provenance for a changed native identity.
            let savedID = value.calendarItemIdentifier
            try refresh()
            let result = try Self.record(resolve(savedID, listID: listID))
            try ReminderWriteWitness.verify(existing: existing, actual: result, fields: fields, completed: completed,
                                            changedFields: changedFields, completionDate: chosen, restoration: restoration)
            return ReminderWriteResult(record: result, completionDate: chosen)
        }
    }

    private static func assignment(_ projected: ReminderDate?, raw: JSON?) throws -> DateComponents? {
        if let raw {
            let restored = try ReminderDate.restoredComponents(raw)
            guard try restored.map(ReminderDate.projected) == projected else { throw CoreError("unsupported_restore", "Raw reminder components do not match the signed fields") }
            return restored
        }
        return projected?.components()
    }
    private static func displayAlarm(_ at: String) throws -> EKAlarm {
        let alarm = EKAlarm(absoluteDate: try parseDate(at))
        alarm.emailAddress = nil; alarm.soundName = nil; alarm.proximity = .none; alarm.structuredLocation = nil
        guard alarm.type == .display else { throw CoreError("unsupported_restore", "Only local display reminder alerts are supported") }
        return alarm
    }
    private static func restoreAlarms(_ values: JSON) throws -> [EKAlarm] {
        try ReminderAlert.validateRaw(values)
        return try values.array!.map { try displayAlarm($0["absolute_date"].string!) }
    }
    private static func location(_ value: EKStructuredLocation?) -> JSON {
        guard let value else { return .null }
        var result: [String: JSON] = ["title": .optional(value.title), "radius": .string(String(value.radius))]
        if let geo = value.geoLocation { result["latitude"] = .string(String(geo.coordinate.latitude)); result["longitude"] = .string(String(geo.coordinate.longitude)) }
        return .object(result)
    }
    private static func recurrence(_ value: EKRecurrenceRule) -> JSON {
        func numbers(_ values: [NSNumber]?) -> JSON { .array((values ?? []).map { .int($0.intValue) }) }
        return .object(["calendar_identifier": .string(value.calendarIdentifier), "frequency": .int(value.frequency.rawValue), "interval": .int(value.interval), "first_day": .int(value.firstDayOfTheWeek),
            "days_of_week": .array((value.daysOfTheWeek ?? []).map { .object(["day": .int($0.dayOfTheWeek.rawValue), "week": .int($0.weekNumber)]) }),
            "days_of_month": numbers(value.daysOfTheMonth), "days_of_year": numbers(value.daysOfTheYear), "weeks_of_year": numbers(value.weeksOfTheYear), "months_of_year": numbers(value.monthsOfTheYear), "set_positions": numbers(value.setPositions),
            "end_date": .optional(value.recurrenceEnd?.endDate.map(iso)), "occurrence_count": value.recurrenceEnd.map { .int($0.occurrenceCount) } ?? .null])
    }
    private static func record(_ value: EKReminder) throws -> ReminderRecord {
        guard let listID = value.calendar?.calendarIdentifier else { throw CoreError("unsupported_reminder", "Reminder list snapshot is unavailable") }
        var reasons: [String] = []
        func projected(_ date: DateComponents?, _ label: String) -> JSON {
            guard let date else { return .null }
            do { return try ReminderDate.projected(date).json }
            catch { reasons.append("unsupported_" + label + "_components"); return .null }
        }
        let fields = try ReminderFields(.object(["title": .string(value.title ?? ""), "notes": .string(value.notes ?? ""), "priority": .int(value.priority),
            "start": projected(value.startDateComponents, "start"), "due": projected(value.dueDateComponents, "due")]), retained: true)
        if fields.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("empty_title") }
        if value.hasRecurrenceRules { reasons.append("recurring_reminder") }
        if value.hasAttendees { reasons.append("unsupported_attendees") }
        let alarms = (value.alarms ?? []).map { alarm -> JSON in
            if alarm.type != .display && alarm.type != .audio { reasons.append("unsupported_external_alarm") }
            return .object(["absolute_date": .optional(alarm.absoluteDate.map(iso)), "relative_offset": .string(String(alarm.relativeOffset)), "proximity": .int(alarm.proximity.rawValue),
                "structured_location": location(alarm.structuredLocation), "type": .int(alarm.type.rawValue), "email_address": .optional(alarm.emailAddress), "sound_name": .optional(alarm.soundName)])
        }
        let sorted = try alarms.map { ($0, try $0.data()) }.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
        var completion: String?
        if let date = value.completionDate {
            let text = iso(date)
            if (try? parseDate(text)) != nil { completion = text } else { reasons.append("unsupported_completion_date") }
        }
        if value.isCompleted != (value.completionDate != nil) { reasons.append("inconsistent_completion_date") }
        let details: JSON = .object(["start_components": ReminderDate.rawComponents(value.startDateComponents), "due_components": ReminderDate.rawComponents(value.dueDateComponents),
            "completion_date_reference": value.completionDate.map { .string(String($0.timeIntervalSinceReferenceDate.bitPattern)) } ?? .null,
            "alarms": .array(sorted), "recurrence_rules": .array((value.recurrenceRules ?? []).map(recurrence)),
            "url": .optional(value.url?.absoluteString), "location": .optional(value.location), "item_time_zone": .optional(value.timeZone?.identifier),
            "external_id": .optional(value.calendarItemExternalIdentifier), "created": .optional(value.creationDate.map(iso)), "modified": .optional(value.lastModifiedDate.map(iso)),
            "attendees": .array((value.attendees ?? []).map { .object(["name": .optional($0.name), "url": .string($0.url.absoluteString), "role": .int($0.participantRole.rawValue), "status": .int($0.participantStatus.rawValue), "type": .int($0.participantType.rawValue)]) })])
        return ReminderRecord(nativeID: value.calendarItemIdentifier, listNativeID: listID, fields: fields, completed: value.isCompleted,
                              completionDate: completion, details: details, unsupportedReasons: Array(Set(reasons)).sorted())
    }
}
