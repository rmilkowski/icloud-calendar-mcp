// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A deliberately bounded creation intent, separate from provider recurrence snapshots.
public struct EventRecurrence: Equatable, Sendable {
    public let frequency: String
    public let interval: Int
    public let daysOfWeek: [Int]?
    public let count: Int?
    public let until: String?

    public init(json: JSON) throws {
        let a = try Arguments(json, allowed: ["frequency", "interval", "days_of_week", "end"], required: ["frequency"])
        frequency = try a.string("frequency")
        guard ["daily", "weekly", "monthly", "yearly"].contains(frequency) else { throw CoreError("invalid_recurrence", "Unsupported recurrence frequency") }
        interval = a.values["interval"]?.integer ?? (a.values["interval"] == nil ? 1 : 0)
        guard (1...999).contains(interval) else { throw CoreError("invalid_recurrence", "Recurrence interval must be an integer from 1 through 999") }
        if let days = a.values["days_of_week"] {
            guard frequency == "weekly", let values = days.array, (1...7).contains(values.count), values.allSatisfy({ $0.integer.map { (1...7).contains($0) } ?? false }), Set(values.compactMap(\.integer)).count == values.count else { throw CoreError("invalid_recurrence", "Use unique weekly weekdays from 1 (Sunday) through 7 (Saturday)") }
            daysOfWeek = values.compactMap(\.integer).sorted()
        } else { daysOfWeek = nil }
        if let end = a.values["end"], end != .null {
            let e = try Arguments(end, allowed: ["count", "until"])
            guard e.values.count == 1 else { throw CoreError("invalid_recurrence", "Specify one recurrence end: count or until") }
            if let value = e.values["count"] {
                guard let number = value.integer, (1...1000).contains(number) else { throw CoreError("invalid_recurrence", "Recurrence count must be an integer from 1 through 1000") }
                count = number; until = nil
            } else { count = nil; until = iso(try parseDate(e.string("until"))) }
        } else { count = nil; until = nil }
    }

    public var json: JSON {
        var values: [String: JSON] = ["frequency": .string(frequency), "interval": .int(interval), "end": count.map { .object(["count": .int($0)]) } ?? until.map { .object(["until": .string($0)]) } ?? .null]
        if let daysOfWeek { values["days_of_week"] = .array(daysOfWeek.map(JSON.int)) }
        return .object(values)
    }

    public func validate(start: Date, zone: TimeZone?) throws {
        guard let zone else { throw CoreError("unsupported_timezone", "Recurring creation requires a named timezone") }
        if let until { guard try parseDate(until) >= start else { throw CoreError("invalid_recurrence", "Recurrence end must not precede the first start") } }
        if let daysOfWeek {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            guard daysOfWeek.contains(calendar.component(.weekday, from: start)) else { throw CoreError("invalid_recurrence", "The first start must fall on a selected weekly weekday") }
        }
    }

    /// Matches the supported public EventKit rule without accepting hidden selectors.
    public func matches(raw: JSON) -> Bool {
        guard let rules = raw.array, rules.count == 1, let rule = rules.first,
              rule["calendar_identifier"] == .string("gregorian"),
              rule["frequency"] == .int(["daily", "weekly", "monthly", "yearly"].firstIndex(of: frequency)!), rule["interval"] == .int(interval),
              let first = rule["first_day"].integer, (frequency == "weekly" && interval > 1 ? first == 2 : [0, 2].contains(first)),
              ["days_of_month", "days_of_year", "weeks_of_year", "months_of_year", "set_positions"].allSatisfy({ rule[$0] == .array([]) }),
              rule["days_of_week"].array?.sorted(by: { ($0["day"].integer ?? 0) < ($1["day"].integer ?? 0) }) == (daysOfWeek ?? []).map({ .object(["day": .int($0), "week": .int(0)]) }) else { return false }
        if let count { return rule["occurrence_count"] == .int(count) && rule["end_date"] == .null }
        if let until { return rule["occurrence_count"] == .int(0) && rule["end_date"] == .string(until) }
        return rule["occurrence_count"] == .null && rule["end_date"] == .null
    }

    /// Synthetic provider output has the same shape as the existing EventKit snapshot.
    public var rawRule: JSON {
        .object(["calendar_identifier": .string("gregorian"), "frequency": .int(["daily", "weekly", "monthly", "yearly"].firstIndex(of: frequency)!), "interval": .int(interval), "first_day": .int(2), "days_of_week": .array((daysOfWeek ?? []).map { .object(["day": .int($0), "week": .int(0)]) }), "days_of_month": .array([]), "days_of_year": .array([]), "weeks_of_year": .array([]), "months_of_year": .array([]), "set_positions": .array([]), "end_date": .optional(until), "occurrence_count": count.map(JSON.int) ?? (until == nil ? .null : .int(0))])
    }
}

extension Broker {
    static let occurrenceRecoveryLimitation = "Restores the displayed fields while preserving the current occurrence and series structure. Historical detachment and series membership are not restored."
    static let copyRecoveryLimitation = "Restoration creates a new provider event. Provider IDs, creation/modification timestamps and read-only status are not restored."
    static let recurringCopyRecoveryLimitation = "Recovery recreates only this occurrence as a standalone event with new provider identity. It does not remove the series exclusion, reattach the occurrence, restore series membership, or make future series edits apply to the copy."

    func recoveryContract(action: String, before: JSON) -> JSON {
        let recurring = before["recurring"] == .bool(true) || before["detached"] == .bool(true)
        let mode = action == "create" ? "not_applicable" : action == "modify" ? "occurrence_fields" : "standalone_copy"
        var limitations: [JSON] = action == "delete" ? [.string(Self.copyRecoveryLimitation)] : []
        if recurring && action == "modify" { limitations.append(.string(Self.occurrenceRecoveryLimitation)) }
        if recurring && action == "delete" { limitations.append(.string(Self.recurringCopyRecoveryLimitation)) }
        return .object(["mode": .string(mode), "limitations": .array(limitations)])
    }

    func hasStandaloneCopyRecoveryContract(_ payload: JSON) -> Bool {
        payload["version"] == .int(3) && payload["action"] == .string("delete") && payload["scope"] == .string("this") && payload["recovery"] == recoveryContract(action: "delete", before: payload["before"])
    }
}
