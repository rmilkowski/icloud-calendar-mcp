import XCTest
import Foundation
import EventKit
@testable import CalendarCore

/// Pure public value constructors only. Never constructs EKEventStore or accesses Calendar data.
final class EventKitRecurrenceTests: XCTestCase {
    func testSupportedIntentsMatchActualPublicRuleConstructors() throws {
        for (name, frequency) in [("daily", EKRecurrenceFrequency.daily), ("weekly", .weekly), ("monthly", .monthly), ("yearly", .yearly)] {
            for interval in [1, 2, 999] {
                for endJSON: JSON in [.null, .object(["count": .int(1)]), .object(["count": .int(1000)]), .object(["until": .string("2027-10-25T10:00:00Z")])] {
                    for selected in name == "weekly" ? [false, true] : [false] {
                        var json: [String: JSON] = ["frequency": .string(name), "interval": .int(interval), "end": endJSON]
                        if selected { json["days_of_week"] = .array([.int(1), .int(4), .int(7)]) }
                        let intent = try EventRecurrence(json: .object(json)), end: EKRecurrenceEnd?
                        if let count = intent.count { end = EKRecurrenceEnd(occurrenceCount: count) }
                        else if let until = intent.until { end = EKRecurrenceEnd(end: try parseDate(until)) }
                        else { end = nil }
                        let days = intent.daysOfWeek?.map { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0)!) }
                        let rule = EKRecurrenceRule(recurrenceWith: frequency, interval: interval, daysOfTheWeek: days, daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
                        func numbers(_ values: [NSNumber]?) -> JSON { .array((values ?? []).map { .int($0.intValue) }) }
                        let observed: JSON = .object(["calendar_identifier": .string(rule.calendarIdentifier), "frequency": .int(rule.frequency.rawValue), "interval": .int(rule.interval), "first_day": .int(rule.firstDayOfTheWeek), "days_of_week": .array((rule.daysOfTheWeek ?? []).map { .object(["day": .int($0.dayOfTheWeek.rawValue), "week": .int($0.weekNumber)]) }), "days_of_month": numbers(rule.daysOfTheMonth), "days_of_year": numbers(rule.daysOfTheYear), "weeks_of_year": numbers(rule.weeksOfTheYear), "months_of_year": numbers(rule.monthsOfTheYear), "set_positions": numbers(rule.setPositions), "end_date": .optional(rule.recurrenceEnd?.endDate.map(iso)), "occurrence_count": rule.recurrenceEnd.map { .int($0.occurrenceCount) } ?? .null])
                        XCTAssertTrue(intent.matches(raw: .array([observed])), "\(intent.json) / \(observed)")
                    }
                }
            }
        }
    }
}
