import Foundation

/// Validates provider snapshots without manufacturing recurrence topology.
public enum FuturePattern {
    public static func boundary(_ selected: EventRecord, now: Date) throws -> Date {
        guard selected.recurring, !selected.detached, let occurrence = selected.occurrence,
              occurrence == selected.fields.start else { throw CoreError("unsupported_scope", "Select an unmodified recurring occurrence at its original start") }
        let date = try parseDate(occurrence)
        guard iso(date) == occurrence, date > now else { throw CoreError("future_boundary_elapsed", "The selected occurrence must still start strictly in the future") }
        return date
    }
    public static func validateRule(_ raw: JSON, boundary: Date) throws {
        let keys: Set<String> = ["calendar_identifier", "frequency", "interval", "first_day", "days_of_week", "days_of_month", "days_of_year", "weeks_of_year", "months_of_year", "set_positions", "end_date", "occurrence_count"]
        guard let rules = raw.array, rules.count == 1, let rule = rules.first, let object = rule.object, Set(object.keys) == keys,
              rule["calendar_identifier"] == .string("gregorian"), let frequency = rule["frequency"].integer, (0...3).contains(frequency),
              let interval = rule["interval"].integer, (1...999).contains(interval), let first = rule["first_day"].integer, (0...7).contains(first),
              rule["occurrence_count"] == .null || rule["occurrence_count"] == .int(0) else { throw CoreError("unsupported_recurrence", "Future changes require one supported unbounded or date-ended recurrence rule; count-ended patterns are unsupported") }
        func numbers(_ key: String, maximum: Int, allowNegative: Bool) -> Bool {
            guard let array = rule[key].array, array.count <= maximum, array.allSatisfy({ value in
                guard let n = value.integer else { return false }
                return allowNegative ? n != 0 && (-maximum...maximum).contains(n) : (1...maximum).contains(n)
            }) else { return false }
            return Set(array.compactMap(\.integer)).count == array.count
        }
        guard numbers("days_of_month", maximum: 31, allowNegative: true), numbers("days_of_year", maximum: 366, allowNegative: true),
              numbers("weeks_of_year", maximum: 53, allowNegative: true), numbers("months_of_year", maximum: 12, allowNegative: false),
              numbers("set_positions", maximum: 366, allowNegative: true), let days = rule["days_of_week"].array, days.count <= 371,
              days.allSatisfy({ day in
                  guard let object = day.object, Set(object.keys) == ["day", "week"], let weekday = day["day"].integer, (1...7).contains(weekday), let week = day["week"].integer, (-53...53).contains(week) else { return false }
                  return true
              }), Set(try days.map { try $0.text() }).count == days.count else { throw CoreError("unsupported_recurrence", "Unsupported provider recurrence selectors") }
        if let end = rule["end_date"].string {
            let date = try parseDate(end)
            guard iso(date) == end, date >= boundary else { throw CoreError("unsupported_recurrence", "The recurrence end must include the selected future boundary") }
        } else if rule["end_date"] != .null { throw CoreError("unsupported_recurrence", "Invalid provider recurrence end") }
    }
    public static func validate(selected: EventRecord, anchor: EventRecord, now: Date) throws -> Date {
        let date = try boundary(selected, now: now)
        guard anchor.recurring, !anchor.detached, let occurrence = anchor.occurrence,
              occurrence == anchor.fields.start, iso(try parseDate(occurrence)) == occurrence,
              try parseDate(occurrence) <= date, anchor.nativeID == selected.nativeID,
              anchor.calendarNativeID == selected.calendarNativeID,
              anchor.details["recurrence_rules"] == selected.details["recurrence_rules"] else { throw CoreError("ambiguous_occurrence", "Selected future occurrence and current first anchor do not establish one provider pattern") }
        if occurrence == selected.occurrence { guard anchor == selected else { throw CoreError("ambiguous_occurrence", "Selected boundary and first anchor snapshots disagree") } }
        try validateRule(selected.details["recurrence_rules"], boundary: date)
        return date
    }
    public static func validPrefixRule(_ raw: JSON, original: JSON, anchor: Date, boundary: Date) throws -> Bool {
        guard let rules = raw.array, rules.count == 1, var prefix = rules[0].object,
              let originals = original.array, originals.count == 1, var prior = originals[0].object,
              let end = prefix.removeValue(forKey: "end_date")?.string,
              let count = prefix.removeValue(forKey: "occurrence_count"), count == .null || count == .int(0) else { return false }
        let date = try parseDate(end), originalEnd = prior.removeValue(forKey: "end_date")
        prior.removeValue(forKey: "occurrence_count")
        guard iso(date) == end, date >= anchor, date < boundary, prefix == prior else { return false }
        if let originalEnd = originalEnd?.string { return date <= (try parseDate(originalEnd)) }
        return originalEnd == .null
    }
}

public struct FutureWriteResult {
    public let boundary: EventRecord
    public let pastAnchor: EventRecord?
    public init(boundary: EventRecord, pastAnchor: EventRecord? = nil) { self.boundary = boundary; self.pastAnchor = pastAnchor }
}
