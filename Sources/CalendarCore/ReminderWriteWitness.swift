// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Supported public witness only; no claim about private Reminders app metadata.
public enum ReminderWriteWitness {
    public static func eligibility(_ value: ReminderRecord) throws {
        guard value.unsupportedReasons.isEmpty,
              value.details["has_recurrence_rules"] != .bool(true),
              value.details["recurrence_rules"].array?.isEmpty != false,
              value.completed == (value.completionDate != nil) else { throw CoreError("unsupported_reminder", "Reminder state is not supported for mutation") }
        _ = try value.exactCompletionDate()
        if value.details.object?["alarms"] != nil, value.details["alarms"].array == nil { throw CoreError("unsupported_reminder", "Reminder alarm witness is invalid") }
        for alarm in value.details["alarms"].array ?? [] {
            guard let type = alarm["type"].integer, type == 0 || type == 1 else { throw CoreError("unsupported_reminder", "External or unknown reminder alarm actions cannot be mutated") }
        }
    }

    public static func restorable(_ value: ReminderRecord, changedFields: [String], recreation: Bool) throws {
        try eligibility(value)
        let mask = Set(changedFields)
        for (field, date) in [("start", value.fields.start), ("due", value.fields.due)] where recreation || mask.contains(field) {
            let raw = value.details[field + "_components"]
            let restored = try ReminderDate.restoredComponents(raw)
            guard try restored.map(ReminderDate.projected) == date else { throw CoreError("unsupported_restore", "Exact retained reminder components are unavailable") }
        }
        if recreation || mask.contains("alerts") { try ReminderAlert.validateRaw(value.details["alarms"]) }
        if recreation {
            guard value.details["attendees"].array?.isEmpty != false,
                  value.details["recurrence_rules"].array?.isEmpty != false,
                  value.details["url"] == .null || value.details["url"].string.flatMap(URL.init(string:)) != nil,
                  value.details["location"] == .null || value.details["location"].string != nil,
                  value.details["item_time_zone"] == .null || value.details["item_time_zone"].string.flatMap(TimeZone.init(identifier:)) != nil else { throw CoreError("unsupported_restore", "Reminder copy metadata cannot be restored safely") }
        }
    }

    public static func verify(existing: ReminderRecord?, actual: ReminderRecord, fields: ReminderFields, completed: Bool,
                              changedFields: [String], completionDate: Date?, restoration: JSON?) throws {
        guard actual.fields == fields.withoutAlerts, actual.completed == completed,
              try actual.exactCompletionDate() == completionDate, actual.unsupportedReasons.isEmpty else { throw CoreError("verification_failed", "Reminder result differs from the exact supported assignment") }
        let mask = Set(changedFields)
        if let existing {
            guard actual.listNativeID == existing.listNativeID else { throw CoreError("verification_failed", "Reminder moved to another list") }
            var mutable: Set<String> = ["modified", "completion_date_reference"]
            if mask.contains("start") { mutable.insert("start_components") }
            if mask.contains("due") { mutable.insert("due_components") }
            if mask.contains("alerts") { mutable.insert("alarms") }
            let keys = Set((existing.details.object ?? [:]).keys).union((actual.details.object ?? [:]).keys)
            for key in keys.subtracting(mutable) {
                guard existing.details.object?[key] == actual.details.object?[key] else { throw CoreError("verification_failed", "Unrequested reminder metadata changed") }
            }
        }
        if let restoration {
            var ignored: Set<String> = ["external_id", "created", "modified", "completion_date_reference"]
            if !mask.contains("start") { ignored.insert("start_components") }
            if !mask.contains("due") { ignored.insert("due_components") }
            if !mask.contains("alerts") { ignored.insert("alarms") }
            for key in Set((restoration.object ?? [:]).keys).subtracting(ignored) {
                guard restoration.object?[key] == actual.details.object?[key] else { throw CoreError("verification_failed", "Retained reminder metadata could not be reproduced exactly") }
            }
        }
        if mask.contains("alerts") {
            let expected: JSON
            if let restoration { expected = restoration["alarms"] }
            else { guard let alerts = fields.alerts else { throw CoreError("verification_failed", "Missing reminder alarm assignment") }; expected = .array(alerts.map(\.rawAlarm)) }
            guard actual.details["alarms"] == expected else { throw CoreError("verification_failed", "Reminder alarm replacement differs from the signed assignment") }
        }
    }
}
