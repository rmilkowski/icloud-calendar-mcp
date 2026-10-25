import Foundation

/// Civil labels projected in a captured native default zone. Event timeZone
/// remains nil; this codec never changes or normalizes an observed snapshot.
public struct AllDayInterval: Equatable, Sendable {
    public let startDate: String, endDateExclusive: String, projectionTimeZone: String
    public let start: Date, endExclusive: Date
    public var writeEnd: Date { endExclusive.addingTimeInterval(-1) }
    public var json: JSON { .object(["start_date": .string(startDate), "end_date_exclusive": .string(endDateExclusive)]) }
    private static let epochOrdinal = 719_162 // Proleptic Gregorian 1970-01-01, zero based.

    /// Independent of Foundation's historical Julian/Gregorian cutover and of
    /// timezone transitions which can omit an entire civil date.
    static func civilOrdinal(_ text: String) throws -> Int {
        guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              let year = Int(text.prefix(4)), (1...9999).contains(year),
              let month = Int(text.dropFirst(5).prefix(2)), (1...12).contains(month),
              let day = Int(text.suffix(2)) else { throw CoreError("invalid_all_day_dates", "Use exact Gregorian YYYY-MM-DD dates within years 0001 through 9999") }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthLengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...monthLengths[month - 1]).contains(day) else { throw CoreError("invalid_all_day_dates", "The civil date is not a real Gregorian date") }
        let priorYear = year - 1, daysBeforeMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
        return 365 * priorYear + priorYear / 4 - priorYear / 100 + priorYear / 400 + daysBeforeMonth[month - 1] + (leap && month > 2 ? 1 : 0) + day - 1
    }

    public init(_ json: JSON, projectionTimeZone: String) throws {
        let args = try Arguments(json, allowed: ["start_date", "end_date_exclusive"], required: ["start_date", "end_date_exclusive"])
        guard let zone = TimeZone(identifier: projectionTimeZone) else { throw CoreError("invalid_timezone", "Native all-day projection timezone is unavailable") }
        startDate = try args.string("start_date"); endDateExclusive = try args.string("end_date_exclusive")
        self.projectionTimeZone = projectionTimeZone
        let labelDays = try Self.civilOrdinal(endDateExclusive) - Self.civilOrdinal(startDate)
        guard (1...366).contains(labelDays) else { throw CoreError("invalid_all_day_dates", "All-day civil labels must span 1 through 366 Gregorian calendar days") }
        start = try Self.midnight(startDate, zone: zone); endExclusive = try Self.midnight(endDateExclusive, zone: zone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let days = calendar.dateComponents([.day], from: start, to: endExclusive).day,
              (1...366).contains(days), calendar.date(byAdding: .day, value: days, to: start) == endExclusive,
              try parseDate(iso(writeEnd)) == writeEnd else { throw CoreError("invalid_all_day_dates", "All-day dates must span 1 through 366 calendar days with an exclusive end") }
    }
    public static func midnight(_ text: String, zone: TimeZone) throws -> Date {
        let ordinal = try civilOrdinal(text)
        let components = DateComponents(era: 1, year: Int(text.prefix(4))!, month: Int(text.dropFirst(5).prefix(2))!, day: Int(text.suffix(2))!, hour: 0, minute: 0, second: 0)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let prolepticMidnight = Date(timeIntervalSince1970: Double(ordinal - epochOrdinal) * 86400)
        guard let date = calendar.date(from: components), calendar.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date) == components,
              calendar.nextDate(after: date.addingTimeInterval(-2 * 86400), matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first) == date,
              calendar.nextDate(after: date.addingTimeInterval(-2 * 86400), matching: components, matchingPolicy: .strict, repeatedTimePolicy: .last) == date,
              date.addingTimeInterval(Double(zone.secondsFromGMT(for: date))) == prolepticMidnight,
              try parseDate(iso(date)) == date else { throw CoreError("invalid_all_day_dates", "The projected date must have one exact, representable local midnight") }
        return date
    }
    public static func label(_ date: Date, zone: TimeZone) throws -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard components.era == 1, let year = components.year, (1...9999).contains(year), let month = components.month, let day = components.day else { throw CoreError("invalid_all_day_dates", "Projected date is outside supported Gregorian years") }
        let text = String(format: "%04d-%02d-%02d", year, month, day), ordinal = try civilOrdinal(text)
        let projectedDay = floor((date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))) / 86400)
        guard projectedDay == Double(ordinal - epochOrdinal) else { throw CoreError("invalid_all_day_dates", "The historical projection does not preserve its proleptic Gregorian civil date") }
        return text
    }
    public static func observed(_ fields: EventFields, projectionTimeZone: String) throws -> AllDayInterval {
        guard fields.allDay, fields.timeZone == nil, fields.recurrence == nil,
              let zone = TimeZone(identifier: projectionTimeZone) else { throw CoreError("unsupported_all_day", "Date changes require a floating all-day event") }
        let start = try parseDate(fields.start), end = try parseDate(fields.end)
        let first = try label(start, zone: zone)
        guard try midnight(first, zone: zone) == start else { throw CoreError("unsupported_all_day", "Observed all-day start is not exact projected midnight") }
        let endLabel = try label(end, zone: zone), last: String
        if try midnight(endLabel, zone: zone) == end { last = endLabel }
        else {
            let candidate = end.addingTimeInterval(1)
            last = try label(candidate, zone: zone)
            guard try midnight(last, zone: zone) == candidate else { throw CoreError("unsupported_all_day", "Observed all-day end is neither exclusive midnight nor inclusive last second") }
        }
        return try AllDayInterval(.object(["start_date": .string(first), "end_date_exclusive": .string(last)]), projectionTimeZone: projectionTimeZone)
    }
    public func materialized(_ fields: EventFields) -> EventFields {
        var result = fields
        result.start = iso(start); result.end = iso(writeEnd); result.timeZone = nil; result.allDay = true; result.recurrence = nil
        return result
    }
    /// EventKit can reinterpret dates when all-day state changes. Establish its
    /// floating state before either endpoint, including on a new event.
    public func assign(setAllDay: (Bool) -> Void, setTimeZone: (TimeZone?) -> Void, setStart: (Date) -> Void, setEnd: (Date) -> Void) {
        setAllDay(true); setTimeZone(nil); setStart(start); setEnd(writeEnd)
    }
    public func matches(_ observed: EventFields) throws -> Bool {
        guard observed.allDay, observed.timeZone == nil, observed.start == iso(start),
              [iso(endExclusive), iso(writeEnd)].contains(observed.end) else { return false }
        return try Self.observed(observed, projectionTimeZone: projectionTimeZone).json == json
    }
}
