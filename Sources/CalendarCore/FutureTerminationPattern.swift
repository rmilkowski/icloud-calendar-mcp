// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct FutureCutoff {
    public let json: JSON
    public let start: Date
    public let end: Date
    public init(_ value: JSON) throws {
        guard let object = value.object else { throw CoreError("invalid_cutoff", "Provide an exact date with named timezone or an offset datetime") }
        if Set(object.keys) == ["at"], let at = value["at"].string {
            start = try parseDate(at); end = start.addingTimeInterval(366 * 86400); try Self.validateWindow(start: start, end: end); json = .object(["at": .string(iso(start))]); return
        }
        guard Set(object.keys) == ["date", "time_zone"], let text = value["date"].string,
              text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let name = value["time_zone"].string, let zone = TimeZone(identifier: name) else { throw CoreError("invalid_cutoff", "Use YYYY-MM-DD with an explicit named timezone") }
        let utc = try parseDate(text + "T00:00:00Z")
        var gregorian = Calendar(identifier: .gregorian); gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = gregorian.dateComponents([.year, .month, .day], from: utc); components.hour = 0; components.minute = 0; components.second = 0
        var local = Calendar(identifier: .gregorian); local.timeZone = zone
        guard let date = local.date(from: components), local.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components else { throw CoreError("invalid_cutoff", "The local date has no exact midnight") }
        let search = date.addingTimeInterval(-86400)
        let first = local.nextDate(after: search, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = local.nextDate(after: search, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .last)
        guard first == date, last == date, let finish = local.date(byAdding: .day, value: 366, to: date), finish > date else { throw CoreError("invalid_cutoff", "The local midnight is ambiguous or the selection window is unavailable") }
        try Self.validateWindow(start: date, end: finish)
        start = date; end = finish; json = .object(["date": .string(text), "time_zone": .string(name)])
    }
    private static func validateWindow(start: Date, end: Date) throws {
        guard (try? parseDate(iso(start))) == start, (try? parseDate(iso(end))) == end else { throw CoreError("invalid_cutoff", "The complete selection window must fit native timestamp bounds") }
    }
    public var window: JSON { .object(["start": .string(iso(start)), "end": .string(iso(end))]) }
}

public enum FutureTerminationPattern {
    /// Derive only rules which the public typed constructor can reproduce exactly.
    public static func copyRecurrence(selected: EventRecord, anchor: EventRecord, now: Date) throws -> EventRecurrence {
        _ = try FuturePattern.validate(selected: selected, anchor: anchor, now: now)
        guard let name = selected.fields.timeZone, name == anchor.fields.timeZone, let zone = TimeZone(identifier: name), selected.fields.allDay == anchor.fields.allDay,
              let raw = selected.details["recurrence_rules"].array?.first, let frequency = raw["frequency"].integer, (0...3).contains(frequency) else { throw CoreError("unsupported_recurrence", "Tail recovery requires an exact typed rule and preserved named timezone") }
        var values: [String: JSON] = ["frequency": .string(["daily", "weekly", "monthly", "yearly"][frequency]), "interval": raw["interval"], "end": raw["end_date"].string.map { .object(["until": .string($0)]) } ?? .null]
        if let days = raw["days_of_week"].array, !days.isEmpty { values["days_of_week"] = .array(days.map { $0["day"] }) }
        let rule = try EventRecurrence(json: .object(values))
        guard rule.matches(raw: selected.details["recurrence_rules"]) else { throw CoreError("unsupported_recurrence", "The provider rule cannot be copied with exact public recurrence semantics") }
        let a = try parseDate(anchor.fields.start), b = try parseDate(selected.fields.start), aEnd = try parseDate(anchor.fields.end), bEnd = try parseDate(selected.fields.end)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let clock = DateFormatter(); clock.locale = Locale(identifier: "en_US_POSIX"); clock.calendar = calendar; clock.timeZone = zone; clock.dateFormat = "HH:mm:ss.SSS"
        let aDays = calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: aEnd)).day
        let bDays = calendar.dateComponents([.day], from: calendar.startOfDay(for: b), to: calendar.startOfDay(for: bEnd)).day
        guard clock.string(from: a) == clock.string(from: b), clock.string(from: aEnd) == clock.string(from: bEnd), aDays == bDays else { throw CoreError("unsupported_recurrence_phase", "The selected occurrence changes the original local time or calendar-day duration") }
        if frequency == 1 {
            let weekday = calendar.component(.weekday, from: b)
            guard rule.daysOfWeek?.contains(weekday) ?? (weekday == calendar.component(.weekday, from: a)) else { throw CoreError("unsupported_recurrence_phase", "The selected weekday cannot start the retained weekly pattern") }
        } else if frequency == 2 {
            guard calendar.component(.day, from: a) == calendar.component(.day, from: b) else { throw CoreError("unsupported_recurrence_phase", "The selected day cannot preserve monthly recurrence phase") }
        } else if frequency == 3 {
            guard calendar.component(.month, from: a) == calendar.component(.month, from: b), calendar.component(.day, from: a) == calendar.component(.day, from: b) else { throw CoreError("unsupported_recurrence_phase", "The selected date cannot preserve yearly recurrence phase") }
        }
        try rule.validate(start: b, zone: zone)
        return rule
    }
    public static func validateRetainedFields(_ fields: EventFields) throws -> (Date, Date, TimeZone?) {
        guard [fields.title, fields.notes, fields.location].allSatisfy({ $0.unicodeScalars.count <= 262_144 }) else { throw CoreError("unsupported_restore", "Retained snapshot text exceeds the native bound") }
        var structural = fields; structural.title = "Retained event"; structural.notes = ""; structural.location = ""
        return try structural.dates()
    }
}

public struct FutureRemovalResult {
    public let pastAnchor: EventRecord?
    public init(pastAnchor: EventRecord? = nil) { self.pastAnchor = pastAnchor }
}
