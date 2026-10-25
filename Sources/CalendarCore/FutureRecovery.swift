import Foundation

extension Broker {
    /// Eligibility is time-sensitive; retained details alone do not promise recovery.
    func futureBoundaryRecoveryProblem(_ execution: (payload: JSON, state: String, result: JSON)) -> String? {
        guard let boundary = execution.payload["future"]["boundary"].string,
              let date = try? parseDate(boundary), date > now() else { return "future_boundary_elapsed" }
        return nil
    }
    func futureRecoveryProblem(_ execution: (payload: JSON, state: String, result: JSON)) -> String? {
        if let problem = futureBoundaryRecoveryProblem(execution) { return problem }
        let boundary = execution.payload["future"]["boundary"].string!
        do {
            guard let id = execution.payload["before"]["id"].string else { return "future_segment_changed" }
            let current = try event(id), currentView = try view(current), anchor = try seriesAnchor(for: current)
            guard current == anchor, current.occurrence == boundary,
                  EventSnapshot.equivalent(currentView, execution.result["event"]),
                  current.details["recurrence_rules"] == execution.payload["before"]["details"]["recurrence_rules"] else { return "future_segment_changed" }
            _ = try FuturePattern.validate(selected: current, anchor: anchor, now: now())
            return nil
        } catch { return "future_segment_changed" }
    }
    func futureRollbackStep(_ sources: [[String]], selectionID: String) throws -> JSON {
        guard sources.count == 1, let row = sources.first, try changeSummary(row)["recovery_eligible"] == .bool(true),
              let execution = try state.execution(row[0]), execution.payload["version"] == .int(5), execution.payload["rollback"] == .null,
              let id = execution.payload["before"]["id"].string, let calendar = execution.payload["calendar"]["id"].string,
              let maskValues = execution.payload["future"]["changed_fields"].array else { throw CoreError("rollback_ineligible", "Select one retained, applied original future change whose exact boundary is still future") }
        try rejectLaterCalendarIntent(after: row, calendar: calendar)
        guard futureRecoveryProblem(execution) == nil else { throw CoreError("stale_rollback", "The exact saved future segment changed or its boundary elapsed") }
        let current = try event(id), before = try view(current), anchor = try seriesAnchor(for: current)
        // Revalidate this exact snapshot: a previous successful read cannot
        // authorize a replacement observed while constructing the signed inverse.
        guard EventSnapshot.equivalent(before, execution.result["event"]), current == anchor,
              current.occurrence == execution.payload["future"]["boundary"].string,
              current.details["recurrence_rules"] == execution.payload["before"]["details"]["recurrence_rules"] else { throw CoreError("stale_rollback", "The future segment changed while preparing its inverse") }
        _ = try FuturePattern.validate(selected: current, anchor: anchor, now: now())
        guard before["calendar"] == execution.payload["calendar"] else { throw CoreError("stale_calendar", "The future segment calendar changed") }
        try checkWritable(before["calendar"], event: current)
        let mask = maskValues.compactMap(\.string)
        guard mask.count == maskValues.count else { throw CoreError("state_corrupt", "Invalid retained future field mask") }
        var after = current.fields.json.object!
        for field in mask where field != "alerts" { after[field] = execution.payload["before"]["fields"][field] }
        _ = try validateSeriesFields(.object(after), before: before, mask: mask, rollback: true)
        let alarms = mask.contains("alerts") ? recoveryDetails(execution.payload["before"]["details"])["alarms"] : .null
        if mask.contains("alerts") { try validateRestorableAlarms(alarms) }
        let expiry = try parseDate(row[5]); guard expiry > now() else { throw CoreError("rollback_ineligible", "Future recovery details expired") }
        let rollback: JSON = .object(["selection_id": .string(selectionID), "source_change_ids": .array([.string(row[0])]), "source_digest": .string(try sourceDigest(sources)), "restoration": .null, "alarm_restoration": alarms, "limitations": .array(Self.futureLimitations.map(JSON.string))])
        return try futurePreview(before: before, anchor: before, after: .object(after), mask: mask, rollback: rollback, expires: expiry)
    }
    func validateFutureRollback(_ envelope: JSON) throws {
        let rollback = try Arguments(envelope["rollback"], allowed: ["selection_id", "source_change_ids", "source_digest", "restoration", "alarm_restoration", "limitations"], required: ["selection_id", "source_change_ids", "source_digest", "restoration", "alarm_restoration", "limitations"])
        let selection = try rollback.string("selection_id")
        guard UUID(uuidString: selection) != nil else { throw CoreError("invalid_preview", "Invalid future recovery selection identity") }
        let sources = try selectedRows(.object(["change_ids": envelope["rollback"]["source_change_ids"]]))
        let expected = try futureRollbackStep(sources, selectionID: selection)["preview"]["envelope"]
        for key in ["action", "scope", "calendar", "after", "recovery"] { guard envelope[key] == expected[key] else { throw CoreError("stale_rollback", "Future recovery sources, fields or current segment changed") } }
        guard EventSnapshot.equivalent(envelope["before"], expected["before"]), EventSnapshot.futureReferenceEquivalent(envelope["future"], expected["future"]),
              EventSnapshot.rollbackMetadataEquivalent(envelope["rollback"], expected["rollback"]) else { throw CoreError("stale_rollback", "Future recovery snapshots, boundary or retained alarms changed") }
    }
}
