// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import CalendarCore

final class ReminderWriteWitnessTests: XCTestCase {
    private func fixture() throws -> ReminderRecord {
        let fields = try ReminderFields(.object(["title": .string("Synthetic reminder"), "notes": .string(""), "priority": .int(0), "start": .null, "due": .null]))
        return ReminderRecord(nativeID: "fixture", listNativeID: "list", fields: fields,
            details: .object(["url": .string("https://example.invalid/fixture"), "location": .string("Fixture location"),
                "start_components": .null, "due_components": .null, "completion_date_reference": .null,
                "recurrence_rules": .array([]), "alarms": .array([.object(["type": .int(1), "sound_name": .string("Basso")])])]))
    }
    func testLocalRichAlarmAndPublicMetadataMustSurviveUnrelatedEdit() throws {
        let before = try fixture()
        var after = before
        after.fields = try ReminderFields.merged(.object(["title": .string("Changed fixture")]), with: before.fields)
        try ReminderWriteWitness.eligibility(before)
        try ReminderWriteWitness.verify(existing: before, actual: after, fields: after.fields, completed: false, changedFields: ["title"], completionDate: nil, restoration: nil)
        for key in ["url", "location", "alarms", "start_components"] {
            var damaged = after; var details = damaged.details.object!; details.removeValue(forKey: key); damaged.details = .object(details)
            XCTAssertThrowsError(try ReminderWriteWitness.verify(existing: before, actual: damaged, fields: after.fields, completed: false, changedFields: ["title"], completionDate: nil, restoration: nil))
        }
    }
    func testExternalUnknownAndRecurringWitnessesRejectBeforeMutation() throws {
        for type in [2, 3, 99] {
            var value = try fixture(); var details = value.details.object!; details["alarms"] = .array([.object(["type": .int(type)])]); value.details = .object(details)
            XCTAssertThrowsError(try ReminderWriteWitness.eligibility(value))
        }
        var recurring = try fixture(); var details = recurring.details.object!; details["recurrence_rules"] = .array([.object(["frequency": .int(0)])]); recurring.details = .object(details)
        XCTAssertThrowsError(try ReminderWriteWitness.eligibility(recurring))
        details["recurrence_rules"] = .array([]); details["has_recurrence_rules"] = .bool(true); recurring.details = .object(details)
        XCTAssertThrowsError(try ReminderWriteWitness.eligibility(recurring))
    }
    func testExplicitAlarmReplacementAndRetainedRawDetailsAreVerified() throws {
        let before = try fixture()
        var after = before
        let assigned = try ReminderFields.merged(.object(["alerts": .array([.object(["at": .string("2030-06-03T09:00:00Z")])])]), with: before.fields)
        after.fields = assigned.withoutAlerts
        var details = after.details.object!; details["alarms"] = .array(assigned.alerts!.map(\.rawAlarm)); after.details = .object(details)
        try ReminderWriteWitness.verify(existing: before, actual: after, fields: assigned, completed: false, changedFields: ["alerts"], completionDate: nil, restoration: nil)
        XCTAssertThrowsError(try ReminderWriteWitness.verify(existing: before, actual: before, fields: assigned, completed: false, changedFields: ["alerts"], completionDate: nil, restoration: nil))
        var copied = before; copied.nativeID = "new-fixture"
        try ReminderWriteWitness.verify(existing: nil, actual: copied, fields: copied.fields, completed: false, changedFields: ["title"], completionDate: nil, restoration: before.details)
        var missing = copied.details.object!; missing["url"] = .null; copied.details = .object(missing)
        XCTAssertThrowsError(try ReminderWriteWitness.verify(existing: nil, actual: copied, fields: copied.fields, completed: false, changedFields: ["title"], completionDate: nil, restoration: before.details))
    }
}
