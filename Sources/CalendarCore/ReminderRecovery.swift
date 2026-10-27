// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

extension ReminderBroker {
    static let envelopeKeys: Set<String> = ["version", "domain", "nonce", "issued_at", "expires_at", "installation_id", "credential_generation", "key_id", "action", "scope", "list", "before", "after", "changed_fields", "completion_date_policy", "recovery", "rollback"]
    func recordFromSnapshot(_ snapshot: JSON, nativeWitness: [String]? = nil) throws -> ReminderRecord {
        _ = try Arguments(snapshot, allowed: ["id", "list_id", "fields", "completed", "completion_date", "details", "fingerprint", "unsupported_reasons"], required: ["id", "list_id", "fields", "completed", "completion_date", "details", "fingerprint", "unsupported_reasons"])
        let binding = try state.resolve(uuid(snapshot["id"].string ?? ""), kind: "reminder"), list = try state.resolve(uuid(snapshot["list_id"].string ?? ""), kind: "list")
        guard binding.listID == list.nativeID, let completed = snapshot["completed"].boolean, snapshot["completion_date"] == .null || snapshot["completion_date"].string != nil, let reasons = snapshot["unsupported_reasons"].array, reasons.allSatisfy({ $0.string != nil }), snapshot["details"].object != nil else { throw CoreError("invalid_preview", "Invalid retained reminder snapshot") }
        let record = ReminderRecord(nativeID: binding.nativeID, listNativeID: binding.listID, fields: try ReminderFields(snapshot["fields"], retained: true), completed: completed, completionDate: snapshot["completion_date"].string, details: snapshot["details"], unsupportedReasons: reasons.compactMap(\.string))
        let candidates = nativeWitness ?? [binding.nativeID]
        for native in candidates {
            var original = record; original.nativeID = native
            if try original.view(id: snapshot["id"].string!, listID: snapshot["list_id"].string!) == snapshot { return original }
        }
        throw CoreError("stale_reminder", "Retained reminder identity or witness changed")
    }
    func restorable(_ record: ReminderRecord) throws {
        try eligible(record)
        try ReminderWriteWitness.restorable(record, changedFields: Self.fields.sorted(), recreation: true)
    }
    func sourceDigest(_ source: ReminderExecution) throws -> String { digest(try JSON.object(["payload": source.payload, "result": source.result]).data()) }
    func recoverySource(_ id: String) throws -> ReminderExecution {
        guard let source = try state.execution(uuid(id)), source.state == "applied", source.detailsAvailable, source.payload["rollback"] == .null else { throw CoreError("recovery_ineligible", "Recovery requires one retained original verified applied reminder change") }
        try state.assertRecoveryUnused(id)
        let sourceRow = try state.rows("SELECT rowid FROM executions WHERE nonce=?", [id])[0][0]
        let sourceMarker = source.marker
        let ids = Set(sourceMarker["affected_ids"].array!.compactMap(\.string) + [source.result["reminder"]["id"].string].compactMap { $0 })
        let native = Set(sourceMarker["native_ids"].array!.compactMap(\.string) + (try ids.map { try state.resolve($0, kind: "reminder").nativeID }))
        for row in try state.rows("SELECT nonce,marker FROM executions WHERE rowid>?", [sourceRow]) {
            if try state.isProvenNotApplied(row[0]) { continue }
            let marker = try state.checkedMarker(JSON.parse(Data(row[1].utf8)), nonce: row[0])
            let otherIDs = Set(marker["affected_ids"].array!.compactMap(\.string)), otherNative = Set(marker["native_ids"].array!.compactMap(\.string))
            if !ids.isDisjoint(with: otherIDs) || !native.isDisjoint(with: otherNative) || marker["source_nonces"].array!.contains(.string(id)) { throw CoreError("intervening_change", "Later reminder history intersects this recovery source") }
            if marker["list_native_id"] == sourceMarker["list_native_id"], marker["action"] == .string("create") { throw CoreError("intervening_change", "Later reminder creation leaves recovery independence unverified") }
        }
        return source
    }
    func rollbackEnvelope(_ id: String) throws -> JSON {
        let source = try recoverySource(id), original = source.payload, originalAction = original["action"].string!
        guard let list = try lists().first(where: { $0.1["id"] == original["list"]["id"] }), list.0.writable else { throw CoreError("list_missing", "Original writable reminder list is unavailable") }
        let before: JSON, after: JSON, action: String, policy: String, mask: [String], retained: ReminderRecord?, restoreDetails: JSON, restoreAlarms: JSON
        if originalAction == "create" {
            let expected = source.result["reminder"]; guard expected != .null else { throw CoreError("recovery_ineligible", "Original create lacks a verified result") }
            let current = try reminder(expected["id"].string!); try eligible(current)
            guard try view(current) == expected else { throw CoreError("stale_reminder", "Created reminder changed since the source") }
            before = expected; after = .null; action = "delete"; policy = "none"; mask = []; retained = nil; restoreDetails = .null; restoreAlarms = .null
        } else {
            let old = try recordFromSnapshot(original["before"], nativeWitness: source.marker["native_ids"].array!.compactMap(\.string)); try eligible(old); retained = old; restoreDetails = old.details
            if originalAction == "delete" {
                do { _ = try backend.get(nativeID: old.nativeID, listID: old.listNativeID); throw CoreError("stale_reminder", "Deleted source is present; copy recovery is unsafe") }
                catch let error as CoreError where error.code == "reminder_missing" { }
                try ReminderWriteWitness.restorable(old, changedFields: Self.fields.sorted(), recreation: true)
                before = .null; action = "create"; mask = Self.fields.sorted(); restoreAlarms = alarms(old.details)
            } else {
                let expected = source.result["reminder"], current = try reminder(expected["id"].string ?? ""); try eligible(current)
                guard try view(current) == expected else { throw CoreError("stale_reminder", "Reminder changed since the verified source result") }
                before = expected; action = "modify"
                var keys = ["title", "notes", "priority", "start", "due"].filter { expected["fields"][$0] != original["before"]["fields"][$0] }
                if expected["completed"] != original["before"]["completed"] || expected["completion_date"] != original["before"]["completion_date"] || expected["details"]["completion_date_reference"] != old.details["completion_date_reference"] { keys.append("completed") }
                if alarms(expected["details"]) != alarms(old.details) { keys.append("alerts") }
                mask = keys.sorted(); guard !mask.isEmpty else { throw CoreError("no_change", "Recovery has no supported field change") }
                try ReminderWriteWitness.restorable(old, changedFields: mask, recreation: false)
                restoreAlarms = mask.contains("alerts") ? alarms(old.details) : .null
            }
            after = old.after; policy = "restore"
        }
        var value = try base(domain: "reminders", action: action)
        value.merge(["scope": .string("this"), "list": list.1, "before": before, "after": after, "changed_fields": .array(mask.map(JSON.string)), "completion_date_policy": .string(policy), "recovery": recovery("none"), "rollback": .object(["source_change_id": .string(id), "source_digest": .string(try sourceDigest(source)), "completion_date": .optional(retained?.completionDate), "alarm_restoration": restoreAlarms, "restoration_details": restoreDetails])]) { _, new in new }
        let envelope = JSON.object(value); try state.assertNoConflict(envelope); return envelope
    }
    func preflightRollback(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["change_id"], required: ["change_id"]), envelope = try rollbackEnvelope(a.string("change_id"))
        return .object(["steps": .array([.object(["commit_tool": .string("commit_reminder_rollback"), "preview": try sign(envelope, domain: "reminders")])]), "limitations": Self.limitations])
    }
    func samePlan(_ first: JSON, _ second: JSON) -> Bool {
        let headers: Set<String> = ["nonce", "issued_at", "expires_at", "installation_id", "credential_generation", "key_id"]
        return first.object?.filter { !headers.contains($0.key) } == second.object?.filter { !headers.contains($0.key) }
    }
}
