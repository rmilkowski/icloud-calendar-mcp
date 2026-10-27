// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

extension ReminderDate {
    private static let rawFields: [(String, Calendar.Component)] = [("era", .era), ("year", .year), ("month", .month), ("day", .day), ("hour", .hour), ("minute", .minute), ("second", .second), ("nanosecond", .nanosecond), ("weekday", .weekday), ("weekday_ordinal", .weekdayOrdinal), ("week_of_month", .weekOfMonth), ("week_of_year", .weekOfYear), ("year_for_week_of_year", .yearForWeekOfYear), ("quarter", .quarter)]
    public static func rawComponents(_ value: DateComponents?) -> JSON {
        guard let value else { return .null }
        var result: [String: JSON] = ["calendar": value.calendar.map { .string(String(describing: $0.identifier)) } ?? .null, "calendar_time_zone": value.calendar.map { .string($0.timeZone.identifier) } ?? .null, "time_zone": .optional(value.timeZone?.identifier), "is_leap_month": value.isLeapMonth.map(JSON.bool) ?? .null]
        for (name, component) in rawFields { result[name] = value.value(for: component).map(JSON.int) ?? .null }
        return .object(result)
    }
    public static func projected(_ value: DateComponents) throws -> ReminderDate {
        guard value.calendar?.identifier == .gregorian, value.era == nil || value.era == 1,
              let y = value.year, let m = value.month, let d = value.day,
              value.nanosecond == nil || value.nanosecond == 0,
              value.weekday == nil, value.weekdayOrdinal == nil, value.weekOfMonth == nil, value.weekOfYear == nil, value.yearForWeekOfYear == nil, value.quarter == nil,
              value.isLeapMonth != true else { throw CoreError("unsupported_reminder_date", "Reminder contains unsupported date components") }
        let time: String?
        if value.hour == nil && value.minute == nil && value.second == nil { time = nil }
        else { guard let hour = value.hour, let minute = value.minute else { throw CoreError("unsupported_reminder_date", "Reminder contains incomplete time components") }; time = String(format: "%02d:%02d:%02d", hour, minute, value.second ?? 0) }
        return try ReminderDate(.object(["date": .string(String(format: "%04d-%02d-%02d", y, m, d)), "time": .optional(time), "time_zone": .optional(value.timeZone?.identifier)]))
    }
    public static func restoredComponents(_ raw: JSON) throws -> DateComponents? {
        if raw == .null { return nil }
        let keys = Set(rawFields.map(\.0) + ["calendar", "calendar_time_zone", "time_zone", "is_leap_month"])
        _ = try Arguments(raw, allowed: keys, required: keys)
        guard raw["calendar"] == .string("gregorian"), let zoneName = raw["calendar_time_zone"].string, let zone = TimeZone(identifier: zoneName), raw["time_zone"] == .null || raw["time_zone"].string.flatMap(TimeZone.init(identifier:)) != nil else { throw CoreError("unsupported_restore", "Retained reminder calendar components cannot be reproduced") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var value = DateComponents(); value.calendar = calendar; value.timeZone = raw["time_zone"].string.flatMap(TimeZone.init(identifier:))
        for (name, component) in rawFields { guard raw[name] == .null || raw[name].integer != nil else { throw CoreError("unsupported_restore", "Invalid retained reminder date component") }; value.setValue(raw[name].integer, for: component) }
        guard raw["is_leap_month"] == .null || raw["is_leap_month"].boolean != nil else { throw CoreError("unsupported_restore", "Invalid reminder leap-month witness") }
        value.isLeapMonth = raw["is_leap_month"].boolean
        _ = try projected(value)
        guard rawComponents(value) == raw else { throw CoreError("unsupported_restore", "Reminder date components cannot be restored exactly") }; return value
    }
}
