import Foundation

extension Broker {
    func executionCalendar(_ row: [String]) throws -> String? {
        let marker = try JSON.parse(Data(row[1].utf8))
        if let id = marker["calendar_id"].string { return id }
        // Legacy metadata can prove independence only while its authenticated
        // encrypted payload is retained. Missing evidence blocks conservatively.
        return try state.execution(row[0])?.payload["calendar"]["id"].string
    }
    func isSeriesExecution(_ row: [String]) throws -> Bool {
        let marker = try JSON.parse(Data(row[1].utf8))
        return marker["future_anchor_id"].string != nil || marker["scope"] == .string("future") || marker["series_anchor_id"].string != nil || (marker["scope"] == .string("series") && marker["action"] == .string("modify"))
    }
    func rejectSeriesCrossing(_ sources: [[String]]) throws {
        guard let earliest = sources.compactMap({ Int($0[7]) }).min(), !sources.isEmpty else { throw CoreError("invalid_selection", "Missing rollback history") }
        for row in try state.recoveryRows() where (Int(row[7]) ?? 0) > earliest {
            if try state.isProvenNotApplied(row) { continue }
            if try isAllDayExecution(row) {
                guard try sources.allSatisfy({ try state.executionsProvenDisjoint($0, from: row) }) else { throw CoreError("rollback_all_day_boundary", "Ordinary recovery cannot cross related civil-date history") }
            }
            if try isSeriesExecution(row) {
                guard try sources.allSatisfy({ try state.executionsProvenDisjoint($0, from: row) }) else { throw CoreError("rollback_series_boundary", "Occurrence recovery cannot cross a possibly related later series default-field intent") }
            }
        }
    }
    func rejectLaterCalendarIntent(after source: [String], calendar: String) throws {
        guard let rowID = Int(source[7]) else { throw CoreError("state_corrupt", "Invalid execution order") }
        for row in try state.recoveryRows() where (Int(row[7]) ?? 0) > rowID {
            if try state.isProvenNotApplied(row) { continue }
            guard try state.executionsProvenDisjoint(source, from: row) else { throw CoreError("rollback_series_boundary", "Possibly related later execution history prevents series default-field recovery") }
        }
    }
    func seriesRollbackStep(_ sources: [[String]], selectionID: String) throws -> JSON {
        guard sources.count == 1, let row = sources.first,
              try changeSummary(row)["recovery_eligible"] == .bool(true), let execution = try state.execution(row[0]),
              execution.payload["version"] == .int(4), execution.payload["rollback"] == .null,
              let eventID = execution.payload["before"]["id"].string,
              let calendarID = execution.payload["calendar"]["id"].string,
              let maskJSON = execution.payload["series"]["changed_fields"].array else { throw CoreError("rollback_ineligible", "Select exactly one retained, applied original series change") }
        try rejectLaterCalendarIntent(after: row, calendar: calendarID)
        let current = try event(eventID), currentView = try view(current), anchor = try seriesAnchor(for: current)
        guard current.nativeID == anchor.nativeID, current.calendarNativeID == anchor.calendarNativeID, current.occurrence == anchor.occurrence,
              EventSnapshot.equivalent(currentView, try view(anchor, knownCalendar: currentView["calendar"])),
              EventSnapshot.equivalent(currentView, execution.result["event"]), currentView["calendar"] == execution.payload["calendar"],
              current.occurrence == execution.payload["before"]["occurrence"].string,
              current.details["recurrence_rules"] == execution.payload["before"]["details"]["recurrence_rules"] else { throw CoreError("stale_rollback", "Current series anchor or pattern differs from the verified source result") }
        try checkWritable(currentView["calendar"], event: current)
        let mask = maskJSON.compactMap(\.string)
        guard mask.count == maskJSON.count else { throw CoreError("state_corrupt", "Invalid retained series field mask") }
        var after = current.fields.json.object!
        for field in mask where field != "alerts" { after[field] = execution.payload["before"]["fields"][field] }
        _ = try validateSeriesFields(.object(after), before: currentView, mask: mask, rollback: true)
        let alarms = mask.contains("alerts") ? recoveryDetails(execution.payload["before"]["details"])["alarms"] : .null
        if mask.contains("alerts") { try validateRestorableAlarms(alarms) }
        let expiry = try parseDate(row[5]); guard expiry > now() else { throw CoreError("rollback_ineligible", "Series recovery details expired") }
        let rollback: JSON = .object(["selection_id": .string(selectionID), "source_change_ids": .array([.string(row[0])]), "source_digest": .string(try sourceDigest(sources)), "restoration": .null, "alarm_restoration": alarms, "limitations": .array(Self.seriesLimitations.map(JSON.string))])
        return try seriesPreview(before: currentView, after: .object(after), selected: currentView, mask: mask, rollback: rollback, expires: expiry)
    }
    func validateSeriesRollback(_ envelope: JSON) throws {
        let rollback = try Arguments(envelope["rollback"], allowed: ["selection_id", "source_change_ids", "source_digest", "restoration", "alarm_restoration", "limitations"], required: ["selection_id", "source_change_ids", "source_digest", "restoration", "alarm_restoration", "limitations"])
        let selection = try rollback.string("selection_id")
        guard UUID(uuidString: selection) != nil else { throw CoreError("invalid_preview", "Invalid series recovery selection identity") }
        let sources = try selectedRows(.object(["change_ids": envelope["rollback"]["source_change_ids"]]))
        let expected = try seriesRollbackStep(sources, selectionID: selection)["preview"]["envelope"]
        for key in ["action", "scope", "calendar", "after", "recovery"] { guard envelope[key] == expected[key] else { throw CoreError("stale_rollback", "Series recovery sources, field mask, lineage or current anchor changed") } }
        guard EventSnapshot.equivalent(envelope["before"], expected["before"]), EventSnapshot.seriesReferenceEquivalent(envelope["series"], expected["series"]),
              EventSnapshot.rollbackMetadataEquivalent(envelope["rollback"], expected["rollback"]) else { throw CoreError("stale_rollback", "Series recovery snapshots or retained alarms changed") }
    }
}
