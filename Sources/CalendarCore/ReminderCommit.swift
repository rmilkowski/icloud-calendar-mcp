// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

private struct ReminderNonEntry: Error { let failure: ProviderMutationFailure }

extension ReminderBroker {
    func ordinarySemantics(_ envelope: JSON) throws {
        guard let action = envelope["action"].string, ["create", "modify", "complete", "reopen", "delete"].contains(action), envelope["scope"] == .string("this"), envelope["rollback"] == .null,
              envelope["recovery"] == recovery(action == "create" ? "delete_created" : action == "delete" ? "limited_copy" : "inverse_fields"),
              let mask = envelope["changed_fields"].array?.compactMap(\.string), envelope["changed_fields"] == .array(mask.map(JSON.string)), mask == Array(Set(mask)).sorted(), Set(mask).isSubset(of: Self.fields) else { throw CoreError("invalid_preview", "Invalid reminder action, recovery or mask") }
        if action == "delete" {
            guard envelope["after"] == .null, envelope["before"] != .null, mask.isEmpty, envelope["completion_date_policy"] == .string("none") else { throw CoreError("invalid_preview", "Invalid reminder delete") }
            try restorable(recordFromSnapshot(envelope["before"])); return
        }
        _ = try Arguments(envelope["after"], allowed: ["fields", "completed"], required: ["fields", "completed"])
        let fields = try ReminderFields(envelope["after"]["fields"], retained: action != "create")
        if action == "create" {
            guard envelope["before"] == .null, fields.alerts != nil, envelope["after"]["completed"] == .bool(false), mask == Self.fields.sorted(), envelope["completion_date_policy"] == .string("clear") else { throw CoreError("invalid_preview", "Invalid reminder creation") }
        } else {
            let old = try recordFromSnapshot(envelope["before"]); try eligible(old)
            if action == "modify" {
                let changed = changed(before: envelope["before"], fields: fields)
                guard !changed.isEmpty, mask == changed, envelope["after"]["completed"] == .bool(old.completed), envelope["completion_date_policy"] == .string("preserve") else { throw CoreError("invalid_preview", "Invalid reminder modification mask or completion policy") }
                var patch: [String: JSON] = [:]; for key in mask { patch[key] = fields.json[key] }
                guard try ReminderFields.merged(.object(patch), with: old.fields) == fields else { throw CoreError("invalid_preview", "Reminder patch changes unmasked values") }
                if fields.alerts != nil { try ReminderAlert.validateRaw(alarms(old.details)) }
            } else {
                let completed = action == "complete"
                guard ["complete", "reopen"].contains(action), fields.json == old.fields.observedJSON, old.completed != completed, envelope["after"]["completed"] == .bool(completed), mask == ["completed"], envelope["completion_date_policy"] == .string(completed ? "set_on_commit" : "clear") else { throw CoreError("invalid_preview", "Invalid reminder completion change") }
            }
        }
    }
    func commit(_ arguments: JSON, expectedAction: String?, rollback: Bool) throws -> JSON {
        let envelope = try authenticate(arguments, keys: Self.envelopeKeys, domain: "reminders"), nonce = envelope["nonce"].string!, action = envelope["action"].string ?? ""
        guard expectedAction == nil || action == expectedAction, (envelope["rollback"] != .null) == rollback else { throw CoreError("invalid_preview", "Reminder preview does not match this commit tool") }
        if let prior = try state.execution(nonce) {
            guard prior.marker["payload_digest"] == .string(digest(try envelope.data())) else { throw CoreError("nonce_conflict", "Consumed reminder nonce binds a different exact preview") }
            try state.recordObservation(replayed: true, operation: rollback ? "commit_reminder_rollback" : "commit_reminder_" + action, now: now()); return prior.result
        }
        guard try state.rows("SELECT nonce FROM assessments WHERE nonce=?", [nonce]).isEmpty else { throw CoreError("nonce_conflict", "Reminder nonce already belongs to an assessment") }
        try fresh(envelope)
        if rollback {
            let expected = try rollbackEnvelope(envelope["rollback"]["source_change_id"].string ?? "")
            guard samePlan(envelope, expected) else { throw CoreError("stale_reminder", "Reminder inverse source or exact review changed") }
        } else { try ordinarySemantics(envelope) }
        guard let list = try lists().first(where: { $0.1 == envelope["list"] }), list.0.writable else { throw CoreError("stale_reminder", "Reminder list changed since preview") }
        let existing: ReminderRecord?
        if envelope["before"] == .null { existing = nil }
        else {
            let current = try reminder(envelope["before"]["id"].string ?? ""); try eligible(current)
            guard try view(current) == envelope["before"], current.listNativeID == list.0.nativeID else { throw CoreError("stale_reminder", "Reminder changed since the exact preview") }; existing = current
        }
        let mask = envelope["changed_fields"].array!.compactMap(\.string), policy = envelope["completion_date_policy"].string!
        let fields = envelope["after"] == .null ? nil : try ReminderFields(envelope["after"]["fields"], retained: true)
        let restoration = rollback && envelope["rollback"]["restoration_details"] != .null ? envelope["rollback"]["restoration_details"] : nil
        let completion: Date?
        if let restoration {
            let source = try recoverySource(envelope["rollback"]["source_change_id"].string!)
            let retained = try recordFromSnapshot(source.payload["before"], nativeWitness: source.marker["native_ids"].array!.compactMap(\.string))
            guard restoration == retained.details else { throw CoreError("invalid_preview", "Raw reminder restoration differs from immutable source") }; completion = try retained.exactCompletionDate()
        } else { completion = policy == "preserve" ? try existing?.exactCompletionDate() : nil }
        let sequence = try state.claim(nonce: nonce, payload: envelope, now: now())
        var failureStage: WriteFailureStage = .providerMutation
        do {
            let written: ReminderWriteResult
            do { written = try backend.apply(action: action, listID: list.0.nativeID, existing: existing, fields: fields, completed: envelope["after"]["completed"].boolean, changedFields: mask, completionPolicy: policy, completionDate: completion, restoration: restoration) }
            catch let failure as ProviderMutationFailure where failure.provesNotEntered { throw ReminderNonEntry(failure: failure) }
            failureStage = .resultVerification
            let result: JSON
            if action == "delete" {
                guard written.record == nil, let existing else { throw CoreError("result_not_verified", "Unexpected reminder delete result") }
                do { _ = try backend.get(nativeID: existing.nativeID, listID: existing.listNativeID); throw CoreError("result_not_verified", "Reminder remains after deletion") }
                catch let error as CoreError where error.code == "reminder_missing" { }
                result = .object(["nonce": .string(nonce), "state": .string("applied"), "action": .string(action), "audit_sequence": .int(sequence), "reminder_id": envelope["before"]["id"], "deleted": .bool(true)])
            } else {
                guard let saved = written.record, saved.listNativeID == list.0.nativeID, let fields, let completed = envelope["after"]["completed"].boolean else { throw CoreError("result_not_verified", "Missing reminder save witness") }
                let current = try backend.get(nativeID: saved.nativeID, listID: saved.listNativeID); try eligible(current)
                guard current == saved, current.fields.observedJSON == fields.observedJSON, current.completed == completed else { throw CoreError("result_not_verified", "Reminder readback does not match reviewed fields") }
                let chosen = policy == "set_on_commit" ? written.completionDate : completion
                if completed { guard let chosen, try current.exactCompletionDate() == chosen else { throw CoreError("result_not_verified", "Reminder completion precision was not verified") } }
                else { guard current.completionDate == nil, current.details["completion_date_reference"] == .null else { throw CoreError("result_not_verified", "Reminder reopening was not verified") } }
                try ReminderWriteWitness.verify(existing: existing, actual: current, fields: fields, completed: completed, changedFields: mask, completionDate: chosen, restoration: restoration)
                let id: String
                if let oldID = envelope["before"]["id"].string {
                    try state.rebindReminder(id: oldID, nativeID: current.nativeID, listNativeID: current.listNativeID); id = oldID
                } else {
                    guard try state.rows("SELECT id FROM identities WHERE kind='reminder' AND native_id=? AND list_native_id=?", [current.nativeID, current.listNativeID]).isEmpty else { throw CoreError("identity_ambiguous", "Created reminder aliases an existing identity") }
                    id = try state.identity(kind: "reminder", nativeID: current.nativeID, listID: current.listNativeID)
                }
                result = .object(["nonce": .string(nonce), "state": .string("applied"), "action": .string(action), "audit_sequence": .int(sequence), "reminder": try view(current, id: id)])
            }
            guard try result.data().count <= 147456 else { throw CoreError("result_not_verified", "Reminder result exceeds retained bounds") }
            failureStage = .outcomePersistence
            try state.finish(nonce: nonce, state: "applied", result: result, event: "write_applied"); return result
        } catch let preEntry as ReminderNonEntry {
            do { return try state.finishNotApplied(nonce: nonce, action: action, failure: preEntry.failure, sequence: sequence) }
            catch { return try uncertain(nonce: nonce, action: action, sequence: sequence, stage: .outcomePersistence, error: error) }
        } catch {
            return try uncertain(nonce: nonce, action: action, sequence: sequence, stage: failureStage, error: error)
        }
    }
    func uncertain(nonce: String, action: String, sequence: Int, stage: WriteFailureStage, error: Error) throws -> JSON {
        let diagnostic: WriteDiagnostic
        if let failure = error as? ProviderMutationFailure, failure.enteredMutation { diagnostic = failure.diagnostic }
        else { diagnostic = WriteDiagnostic(stage: stage, error: error) }
        let result: JSON = .object(["nonce": .string(nonce), "state": .string("unknown"), "action": .string(action), "audit_sequence": .int(sequence), "diagnostic": diagnostic.json, "message": .string("The reminder outcome is uncertain. Do not retry the write. Inspect get_reminder_change_status and get_stored_reminder_change, then use an explicit user assessment through preflight_reminder_reconciliation and commit_reminder_reconciliation if needed")])
        try budget(result, utf8: 16384, ascii: 32768)
        do { try state.finish(nonce: nonce, state: "unknown", result: result, event: "write_unknown") } catch { /* The durable intent remains unresolved; a nonblocking outcome is never returned. */ }
        return result
    }
}
