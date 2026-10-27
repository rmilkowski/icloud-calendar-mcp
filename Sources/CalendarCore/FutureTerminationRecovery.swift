// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

extension Broker {
    func recordFromSnapshot(_ snapshot: JSON) throws -> EventRecord {
        guard EventSnapshot.equivalent(snapshot, snapshot), let id = snapshot["id"].string,
              let recurring = snapshot["recurring"].boolean, let detached = snapshot["detached"].boolean,
              let attendees = snapshot["has_attendees"].boolean, let organizer = snapshot["has_organizer"].boolean,
              let availability = snapshot["availability"].string, let status = snapshot["status"].string else { throw CoreError("state_corrupt", "Retained event snapshot is invalid") }
        let binding = try state.resolve(id, kind: "event")
        guard binding.occurrence == snapshot["occurrence"].string else { throw CoreError("stale_rollback", "Original occurrence binding changed") }
        return EventRecord(nativeID: binding.nativeID, calendarNativeID: binding.calendarID, occurrence: binding.occurrence, fields: try EventFields(json: snapshot["fields"]), recurring: recurring, detached: detached, hasAttendees: attendees, hasOrganizer: organizer, availability: availability, status: status, details: snapshot["details"])
    }
    func retainedPrefixMaster(_ snapshot: JSON) throws -> EventRecord {
        let retained = try recordFromSnapshot(snapshot)
        return try FuturePattern.prefixMaster(backend.firstSeriesOccurrence(for: retained), retained: retained)
    }
    func terminationRestoreState(_ execution: (payload: JSON, state: String, result: JSON)) throws -> (selected: EventRecord, past: JSON, calendar: JSON, fields: EventFields) {
        let source = execution.payload
        guard source["version"] == .int(6), source["action"] == .string("delete"), source["rollback"] == .null,
              source["recovery"] == Self.terminationRecovery, execution.state == "applied",
              let boundaryText = source["future"]["boundary"].string,
              source["before"]["occurrence"] == .string(boundaryText), source["before"]["fields"]["start"] == .string(boundaryText) else { throw CoreError("rollback_ineligible", "Select an applied original future termination with its exact independent-copy contract") }
        let selected = try recordFromSnapshot(source["before"]), anchor = try recordFromSnapshot(source["future"]["first_anchor"])
        let rule = try FutureTerminationPattern.copyRecurrence(selected: selected, anchor: anchor, now: parseDate(boundaryText).addingTimeInterval(-0.001))
        guard rule.json == source["future"]["copy_recurrence"], source["future"]["removes_entire_current_pattern"] == .bool(selected.occurrence == anchor.occurrence) else { throw CoreError("state_corrupt", "Retained copy rule or whole-pattern flag changed") }
        try requireAbsent(selected)
        let past: JSON
        if selected.occurrence == anchor.occurrence {
            try requireAbsent(anchor); guard execution.result["past_anchor"] == .null else { throw CoreError("state_corrupt", "Unexpected retained prefix") }; past = .null
        } else {
            guard let id = execution.result["past_anchor"]["id"].string, id == source["future"]["first_anchor"]["id"].string else { throw CoreError("state_corrupt", "Missing original prefix identity") }
            let current = try retainedPrefixMaster(execution.result["past_anchor"]); past = try view(current)
            guard EventSnapshot.equivalent(past, execution.result["past_anchor"]) else { throw CoreError("stale_rollback", "Original prefix changed or regrew after termination") }
            try verifiedEarlierAnchor(current, original: anchor, boundary: selected)
        }
        guard let calendar = try calendars().first(where: { $0.1["id"] == source["calendar"]["id"] })?.1, calendar == source["calendar"] else { throw CoreError("stale_calendar", "The original calendar changed") }
        try checkWritable(calendar); try checkTailCopyRestorable(selected)
        var fields = selected.fields; fields.recurrence = rule
        _ = try FutureTerminationPattern.validateRetainedFields(fields)
        return (selected, past, calendar, fields)
    }
    func terminationRollbackStep(_ sources: [[String]], selectionID: String) throws -> JSON {
        guard sources.count == 1, let row = sources.first, try changeSummary(row)["recovery_eligible"] == .bool(true),
              let execution = try state.execution(row[0]), let calendar = execution.payload["calendar"]["id"].string else { throw CoreError("rollback_ineligible", "Select one retained applied original future termination") }
        try rejectLaterCalendarIntent(after: row, calendar: calendar)
        let verified = try terminationRestoreState(execution), expiry = try parseDate(row[5])
        guard expiry > now() else { throw CoreError("rollback_ineligible", "The retained independent-copy source expired") }
        let restoration: JSON = .object(["details": recoveryDetails(execution.payload["before"]["details"]), "availability": execution.payload["before"]["availability"], "past_anchor": verified.past])
        let rollback: JSON = .object(["selection_id": .string(selectionID), "source_change_ids": .array([.string(row[0])]), "source_digest": .string(try sourceDigest(sources)), "restoration": restoration, "limitations": .array(Self.terminationLimitations.map(JSON.string))])
        return try terminationPreview(action: "create", calendar: verified.calendar, before: .null, after: verified.fields.json, future: execution.payload["future"], rollback: rollback, expires: expiry)
    }
    func validateTerminationRollback(_ envelope: JSON) throws -> (selected: EventRecord, past: JSON, calendar: JSON, fields: EventFields) {
        let r = try Arguments(envelope["rollback"], allowed: ["selection_id", "source_change_ids", "source_digest", "restoration", "limitations"], required: ["selection_id", "source_change_ids", "source_digest", "restoration", "limitations"])
        let selection = try r.string("selection_id")
        guard UUID(uuidString: selection) != nil else { throw CoreError("invalid_preview", "Invalid recovery selection") }
        let rows = try selectedRows(.object(["change_ids": envelope["rollback"]["source_change_ids"]]))
        let expected = try terminationRollbackStep(rows, selectionID: selection)["preview"]["envelope"]
        for key in ["action", "scope", "calendar", "before", "after", "future", "recovery"] { guard envelope[key] == expected[key] else { throw CoreError("stale_rollback", "The independent-copy source, prefix or creation fields changed") } }
        guard EventSnapshot.rollbackMetadataEquivalent(envelope["rollback"], expected["rollback"]), let row = rows.first, let execution = try state.execution(row[0]) else { throw CoreError("stale_rollback", "The retained source or restoration changed") }
        // Recheck the exact source bridge again; no later read may supply replacement fields.
        let verified = try terminationRestoreState(execution)
        guard verified.fields.json == envelope["after"], EventSnapshot.equivalent(verified.past, envelope["rollback"]["restoration"]["past_anchor"]) else { throw CoreError("stale_rollback", "The source prefix changed during recovery validation") }
        return verified
    }
    func commitFutureRestore(_ arguments: JSON) throws -> JSON {
        let envelope = try authenticateTermination(arguments, restore: true), nonce = envelope["nonce"].string!
        if let prior = try state.execution(nonce) {
            guard try state.payloadMatches(nonce: nonce, payload: envelope) else { throw CoreError("nonce_conflict", "Nonce payload differs from recorded execution") }
            try state.recordCommitObservation(replayed: true, operation: "commit_future_restore", now: now()); return prior.result
        }
        guard envelope["after"]["all_day"] != .bool(true) else { throw CoreError("unsupported_restore", "All-day independent-copy recovery is unsupported") }
        _ = try terminationFreshTime(envelope, restore: true)
        try state.assertNoUnresolvedConflict(payload: envelope)
        let verified = try validateTerminationRollback(envelope)
        let claimedAt = try terminationFreshTime(envelope, restore: true)
        let sequence = try state.claim(nonce: nonce, payload: envelope, now: claimedAt)
        let result: JSON
        var verificationStage: WriteFailureStage = .providerMutation
        do {
            let prefix = verified.past == .null ? nil : try recordFromSnapshot(verified.past)
            let saved = try providerMutation { try backend.restoreFutureTail(calendarID: verified.selected.calendarNativeID, originalSelected: verified.selected, expectedPrefix: prefix, fields: verified.fields, details: envelope["rollback"]["restoration"]["details"], availability: verified.selected.availability) }
            verificationStage = .resultVerification
            let first = try backend.firstSeriesOccurrence(for: saved)
            guard saved == first, saved.nativeID != verified.selected.nativeID, saved.calendarNativeID == verified.selected.calendarNativeID,
                  saved.occurrence == envelope["future"]["boundary"].string, saved.recurring, !saved.detached,
                  saved.fields == verified.fields.withoutAlerts, saved.availability == verified.selected.availability,
                  !saved.hasAttendees, !saved.hasOrganizer,
                  verified.fields.recurrence?.matches(raw: saved.details["recurrence_rules"]) == true,
                  EventSnapshot.detailsEquivalent(recoveryDetails(saved.details), envelope["rollback"]["restoration"]["details"]) else { throw CoreError("verification_failed", "The independent copied series differs from the exact retained creation") }
            verificationStage = .boundaryAbsence
            try requireAbsent(verified.selected)
            if verified.past != .null {
                verificationStage = .prefixVerification
                guard EventSnapshot.equivalent(try view(retainedPrefixMaster(verified.past)), verified.past) else { throw CoreError("verification_failed", "The original prefix changed during independent-copy creation") }
            }
            guard try state.rows("SELECT id FROM identities WHERE kind='event' AND native_id=? AND calendar_id=? AND occurrence=?", [saved.nativeID, saved.calendarNativeID, saved.occurrence ?? ""]).isEmpty else { throw CoreError("verification_failed", "Independent creation returned a previously bound event identity") }
            let newView = try view(saved)
            guard newView["id"] != envelope["future"]["reference"]["id"], newView["id"] != envelope["future"]["first_anchor"]["id"] else { throw CoreError("verification_failed", "Independent-copy identity aliases an original reference") }
            result = .object(["nonce": .string(nonce), "state": .string("applied"), "action": .string("create"), "event": newView, "past_anchor": verified.past, "restored_from": envelope["rollback"]["source_change_ids"], "rollback_of": envelope["rollback"]["source_change_ids"], "audit_sequence": .int(sequence)])
        } catch {
            return writeFailure(error, nonce: nonce, action: "create", sequence: sequence, stage: verificationStage)
        }
        do { try state.finish(nonce: nonce, state: "applied", result: result, event: "write_applied"); return result }
        catch { return unknownWrite(error, nonce: nonce, action: "create", sequence: sequence, stage: .outcomePersistence) }
    }
}
