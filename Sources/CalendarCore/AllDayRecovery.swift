// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

extension Broker {
    func isAllDayExecution(_ row: [String]) throws -> Bool {
        let marker = try JSON.parse(Data(row[1].utf8))
        if marker["all_day_version"] == .int(7) { return true }
        return try state.execution(row[0])?.payload["version"] == .int(7)
    }
    func allDayRollbackStep(_ sources: [[String]], selectionID: String) throws -> JSON {
        guard sources.count == 1, let row = sources.first, try changeSummary(row)["recovery_eligible"] == .bool(true),
              let execution = try state.execution(row[0]), execution.payload["version"] == .int(7), execution.payload["action"] == .string("modify"), execution.payload["rollback"] == .null,
              let eventID = execution.payload["before"]["id"].string, let calendarID = execution.payload["calendar"]["id"].string else { throw CoreError("rollback_ineligible", "Select exactly one retained applied original civil-date modification") }
        let (sourceInterval, _) = try validateAllDayEnvelope(execution.payload, rollback: false)
        try requireAllDayZone(sourceInterval.projectionTimeZone)
        try rejectLaterCalendarIntent(after: row, calendar: calendarID)
        let current = try event(eventID), before = try view(current)
        guard EventSnapshot.equivalent(before, execution.result["event"]), before["calendar"] == execution.payload["calendar"] else { throw CoreError("stale_rollback", "Current all-day event differs from the verified source result") }
        try checkWritable(before["calendar"], event: current); try checkAllDayTarget(current)
        let interval = try AllDayInterval(execution.payload["all_day"]["before"], projectionTimeZone: sourceInterval.projectionTimeZone)
        let original = try EventFields(json: execution.payload["before"]["fields"])
        var fields = interval.materialized(original); fields.alerts = nil
        try validateAllDayText(fields, retained: true)
        let alarms = recoveryDetails(execution.payload["before"]["details"])["alarms"]
        try validateRestorableAlarms(alarms)
        guard current.details["structured_location"] == execution.payload["before"]["details"]["structured_location"], current.details["url"] == execution.payload["before"]["details"]["url"] else { throw CoreError("stale_rollback", "Unrelated retained all-day properties changed") }
        let expiry = try parseDate(row[5]); guard expiry > now() else { throw CoreError("rollback_ineligible", "Civil-date recovery details expired") }
        let rollback: JSON = .object(["selection_id": .string(selectionID), "source_change_ids": .array([.string(row[0])]), "source_digest": .string(try sourceDigest(sources)), "restoration": .null, "alarm_restoration": alarms, "limitations": .array([.string(Self.allDayRecoveryLimitation)])])
        var step = try allDayPreview(action: "modify", calendar: before["calendar"], before: before, fields: fields, interval: interval, rollback: rollback, expires: expiry).object!
        step["commit_tool"] = .string("commit_rollback")
        return .object(step)
    }
    func validateAllDayRollback(_ envelope: JSON) throws {
        let rollback = try Arguments(envelope["rollback"], allowed: ["selection_id", "source_change_ids", "source_digest", "restoration", "alarm_restoration", "limitations"], required: ["selection_id", "source_change_ids", "source_digest", "restoration", "alarm_restoration", "limitations"])
        let selection = try rollback.string("selection_id")
        guard UUID(uuidString: selection) != nil else { throw CoreError("invalid_preview", "Invalid all-day recovery selection") }
        let rows = try selectedRows(.object(["change_ids": envelope["rollback"]["source_change_ids"]]))
        let expected = try allDayRollbackStep(rows, selectionID: selection)["preview"]["envelope"]
        for key in ["action", "scope", "calendar", "after", "all_day", "recovery"] {
            guard envelope[key] == expected[key] else { throw CoreError("stale_rollback", "All-day recovery source, dates or metadata changed") }
        }
        guard EventSnapshot.equivalent(envelope["before"], expected["before"]), EventSnapshot.rollbackMetadataEquivalent(envelope["rollback"], expected["rollback"]) else { throw CoreError("stale_rollback", "All-day recovery snapshot or retained alarms changed") }
    }
}
