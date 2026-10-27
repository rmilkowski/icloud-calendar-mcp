// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

extension ReminderStateStore {
    static let nonExecutionMessage = "The reminder provider API was not entered. The nonce and quota stay consumed; a new attempt requires a fresh exact preview and host confirmation"
    private static let nonExecutionKeys: Set<String> = ["nonce", "state", "action", "audit_sequence", "execution_evidence", "diagnostic", "message"]
    private static let markerKeys: Set<String> = ["resource", "version", "action", "list_id", "list_native_id", "reminder_id", "native_ids", "affected_ids", "source_nonces", "source_change_id", "identity_cutoff", "payload_digest"]
    func reminderMarker(_ payload: JSON, nonce: String) throws -> JSON {
        guard let list = payload["list"]["id"].string else { throw CoreError("invalid_preview", "Reminder list binding missing") }
        let listBinding = try resolve(list, kind: "list")
        var ids: Set<String> = [], native: Set<String> = [], sources: Set<String> = [nonce]
        if let id = payload["before"]["id"].string {
            let binding = try resolve(id, kind: "reminder")
            guard binding.listID == listBinding.nativeID else { throw CoreError("invalid_preview", "Reminder list binding changed") }
            ids.insert(id); native.insert(binding.nativeID)
        }
        var pending = payload["rollback"]["source_change_id"].string.map { [$0] } ?? [], visited: Set<String> = []
        while let source = pending.popLast() {
            guard visited.count < 128, visited.insert(source).inserted, let row = try rows("SELECT marker,source_nonce FROM executions WHERE nonce=?", [source]).first else { throw CoreError("state_corrupt", "Invalid Reminders recovery dependency") }
            let marker = try checkedMarker(JSON.parse(Data(row[0].utf8)), nonce: source)
            sources.formUnion(marker["source_nonces"].array!.compactMap(\.string)); ids.formUnion(marker["affected_ids"].array!.compactMap(\.string)); native.formUnion(marker["native_ids"].array!.compactMap(\.string))
            if let result = try execution(source)?.result["reminder"]["id"].string { ids.insert(result) }
            if !row[1].isEmpty { pending.append(row[1]) }
        }
        for id in ids { native.insert(try resolve(id, kind: "reminder").nativeID) }
        return .object(["resource": .string("reminders"), "version": .int(1), "action": payload["action"], "list_id": .string(list), "list_native_id": .string(listBinding.nativeID), "reminder_id": payload["before"]["id"], "native_ids": .array(native.sorted().map(JSON.string)), "affected_ids": .array(ids.sorted().map(JSON.string)), "source_nonces": .array(sources.sorted().map(JSON.string)), "source_change_id": payload["rollback"]["source_change_id"], "identity_cutoff": .int(Int(try rows("SELECT COALESCE(MAX(rowid),0) FROM identities")[0][0])!), "payload_digest": .string(digest(try payload.data()))])
    }
    func checkedMarker(_ marker: JSON, nonce: String) throws -> JSON {
        guard let object = marker.object, Set(object.keys) == Self.markerKeys, marker["resource"] == .string("reminders"), marker["version"] == .int(1),
              ["create", "modify", "complete", "reopen", "delete"].contains(marker["action"].string ?? ""),
              marker["list_id"].string.flatMap(UUID.init(uuidString:)) != nil, let nativeList = marker["list_native_id"].string, !nativeList.isEmpty,
              marker["reminder_id"] == .null || marker["reminder_id"].string.flatMap(UUID.init(uuidString:)) != nil,
              marker["source_change_id"] == .null || marker["source_change_id"].string.flatMap(UUID.init(uuidString:)) != nil,
              let native = marker["native_ids"].array, native.count <= 128, native.allSatisfy({ $0.string?.isEmpty == false }), Set(native.compactMap(\.string)).count == native.count,
              let ids = marker["affected_ids"].array, ids.count <= 128, ids.allSatisfy({ $0.string.flatMap(UUID.init(uuidString:)) != nil }), Set(ids.compactMap(\.string)).count == ids.count,
              let sources = marker["source_nonces"].array, sources.count <= 128, sources.allSatisfy({ $0.string.flatMap(UUID.init(uuidString:)) != nil }), Set(sources.compactMap(\.string)).count == sources.count, sources.contains(.string(nonce)),
              let cutoff = marker["identity_cutoff"].integer, cutoff >= 0, cutoff <= Int(try rows("SELECT COALESCE(MAX(rowid),0) FROM identities")[0][0])!,
              let hash = marker["payload_digest"].string, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CoreError("state_corrupt", "Invalid immutable Reminders marker") }
        let binding = try resolve(marker["list_id"].string!, kind: "list")
        guard binding.nativeID == nativeList else { throw CoreError("state_corrupt", "Stored Reminders list identity changed") }
        if marker["action"] != .string("create") { guard let id = marker["reminder_id"].string, ids.contains(.string(id)), !native.isEmpty else { throw CoreError("state_corrupt", "Stored reminder target evidence missing") } }
        if let source = marker["source_change_id"].string { guard source != nonce, sources.contains(.string(source)) else { throw CoreError("state_corrupt", "Missing immutable reminder dependency") } }
        return marker
    }
    func assertNoConflict(_ payload: JSON) throws {
        let candidate = try reminderMarker(payload, nonce: payload["nonce"].string!)
        let ids = Set(candidate["affected_ids"].array!.compactMap(\.string)), sources = Set(candidate["source_nonces"].array!.compactMap(\.string))
        var native = Set(candidate["native_ids"].array!.compactMap(\.string))
        for id in ids { native.insert(try resolve(id, kind: "reminder").nativeID) }
        for row in try rows("SELECT nonce,marker FROM executions WHERE state IN ('intent_recorded','unknown')") {
            let marker = try checkedMarker(JSON.parse(Data(row[1].utf8)), nonce: row[0]), oldIDs = Set(marker["affected_ids"].array!.compactMap(\.string))
            var oldNative = Set(marker["native_ids"].array!.compactMap(\.string))
            for id in oldIDs { oldNative.insert(try resolve(id, kind: "reminder").nativeID) }
            guard ids.isDisjoint(with: oldIDs), native.isDisjoint(with: oldNative), sources.isDisjoint(with: marker["source_nonces"].array!.compactMap(\.string)) else { throw CoreError("unresolved_write", "Uncertain reminder identity or recovery dependency; inspect its journal without retrying") }
            if candidate["list_native_id"] != marker["list_native_id"] { continue }
            guard marker["action"] != .string("create") else { throw CoreError("unresolved_write", "An uncertain reminder creation holds its list; inspect its original journal") }
            guard let target = payload["before"]["id"].string else { throw CoreError("unresolved_write", "An uncertain reminder may affect this list; inspect its journal") }
            let binding = try resolve(target, kind: "reminder")
            guard let witness = try rows("SELECT rowid FROM identities WHERE kind='reminder' AND native_id=? AND list_native_id=? AND rowid<=?", [binding.nativeID, binding.listID, String(marker["identity_cutoff"].integer!)]).first, Int(witness[0]) != nil else { throw CoreError("unresolved_write", "Reminder independence lacks a prior exact identity witness") }
        }
    }
    func isProvenNotApplied(_ nonce: String) throws -> Bool {
        guard let row = try rows("SELECT state,result FROM executions WHERE nonce=?", [nonce]).first, row[0] == "not_applied" else { return false }
        guard provenNonExecution[nonce] == digest(Data(row[1].utf8)) else { throw CoreError("state_corrupt", "Reminders non-entry evidence changed") }; return true
    }
    func assertRecoveryUnused(_ source: String) throws {
        for row in try rows("SELECT nonce FROM executions WHERE source_nonce=?", [source]) { guard try isProvenNotApplied(row[0]) else { throw CoreError("rollback_used", "Reminder source already has a recovery attempt") } }
    }
    func finishNotApplied(nonce: String, action: String, failure: ProviderMutationFailure, sequence: Int) throws -> JSON {
        guard failure.provesNotEntered else { throw CoreError("state_corrupt", "Missing native Reminders non-entry proof") }
        let proof: JSON = .object(["version": .int(1), "provider_mutation": .string("not_entered")])
        let result: JSON = .object(["nonce": .string(nonce), "state": .string("not_applied"), "action": .string(action), "audit_sequence": .int(sequence), "execution_evidence": proof, "diagnostic": failure.diagnostic.json, "message": .string(Self.nonExecutionMessage)])
        let minimalText = try transaction { () throws -> String in
            guard let old = try execution(nonce), old.state == "intent_recorded", old.marker["action"] == .string(action), try rows("SELECT sequence FROM audit WHERE sequence=?", [String(sequence)]).count == 1, let raw = try rows("SELECT key FROM execution_keys WHERE nonce=?", [nonce]).first, let key = Data(base64Encoded: raw[0]) else { throw CoreError("audit_unavailable", "Cannot durably bind Reminders non-entry evidence") }
            guard let intentRow = try rows("SELECT body FROM audit WHERE sequence=?", [String(sequence)]).first else { throw CoreError("state_corrupt", "Missing reminder intent sequence") }
            let intentAudit = try JSON.parse(Data(intentRow[0].utf8))
            guard intentAudit["event"] == .string("write_intent"), intentAudit["nonce"] == .string(nonce), intentAudit["payload"]["detail_digest"] == .string(digest(try old.marker.data())) else { throw CoreError("state_corrupt", "Reminder proof intent context differs") }
            let minimal = try minimal(result, nonce: nonce, state: "not_applied").text()
            try execute("UPDATE details SET result_cipher=? WHERE nonce=?", [try crypt(result, key: key, nonce: nonce, field: "result_cipher"), nonce])
            try execute("UPDATE executions SET state='not_applied',result=? WHERE nonce=? AND state='intent_recorded'", [minimal, nonce])
            _ = try appendInside("write_not_applied", nonce: nonce, payload: result)
            return minimal
        }
        provenNonExecution[nonce] = digest(Data(minimalText.utf8)); return result
    }
    func validateHistory(audits: [String: [JSON]]) throws {
        var validated: [String: String] = [:]
        var held = Set(try rows("SELECT nonce FROM executions WHERE state IN ('unknown','intent_recorded')").map { $0[0] }), pending = Array(held)
        while let nonce = pending.popLast() {
            guard let row = try rows("SELECT source_nonce FROM executions WHERE nonce=?", [nonce]).first else { throw CoreError("state_corrupt", "Missing unresolved reminder dependency") }
            if !row[0].isEmpty, held.insert(row[0]).inserted { pending.append(row[0]) }
        }
        for row in try rows("SELECT nonce,marker,state,result,source_nonce FROM executions") {
            let nonce = row[0], marker = try checkedMarker(JSON.parse(Data(row[1].utf8)), nonce: nonce), minimal = try JSON.parse(Data(row[3].utf8))
            guard UUID(uuidString: nonce)?.uuidString == nonce, ["intent_recorded", "applied", "unknown", "not_applied", "reconciled"].contains(row[2]), minimal["nonce"] == .string(nonce), minimal["state"] == .string(row[2]), minimal["action"] == marker["action"], (marker["source_change_id"].string ?? "") == row[4],
                  let intent = audits[nonce]?.filter({ $0["event"] == .string("write_intent") }), intent.count == 1, intent[0]["payload"]["payload_digest"] == marker["payload_digest"], intent[0]["payload"]["detail_digest"] == .string(digest(try marker.data())) else { throw CoreError("state_corrupt", "Reminders immutable history binding failed") }
            if !row[4].isEmpty { guard try rows("SELECT nonce FROM executions WHERE nonce=?", [row[4]]).count == 1 else { throw CoreError("state_corrupt", "Missing Reminders recovery parent") } }
            let payload = try secret(nonce, field: "payload_cipher"), result = try secret(nonce, field: "result_cipher")
            if let payload { guard payload["domain"] == .string("reminders"), payload["nonce"] == .string(nonce), payload["action"] == marker["action"], payload["list"]["id"] == marker["list_id"], payload["before"]["id"] == marker["reminder_id"], payload["rollback"]["source_change_id"] == marker["source_change_id"], marker["payload_digest"] == .string(digest(try payload.data())) else { throw CoreError("state_corrupt", "Retained Reminders payload disagrees with immutable marker") } }
            guard let detail = try rows("SELECT expired,captured,expires FROM details WHERE nonce=?", [nonce]).first, ["0", "1"].contains(detail[0]), (detail[0] == "0") == (payload != nil), (payload != nil) == (result != nil), try parseDate(detail[2]) > parseDate(detail[1]) else { throw CoreError("state_corrupt", "Invalid Reminders retained detail state") }
            if held.contains(nonce), detail[0] != "0" { throw CoreError("state_corrupt", "Unresolved reminder details or dependency expired") }
            if detail[0] == "1" { guard try rows("SELECT nonce FROM execution_keys WHERE nonce=?", [nonce]).isEmpty else { throw CoreError("state_corrupt", "Expired Reminders key remains available") } }
            if let result { guard result["nonce"] == .string(nonce), result["state"] == .string(row[2]), result["action"] == marker["action"], minimal == self.minimal(result, nonce: nonce, state: row[2]) else { throw CoreError("state_corrupt", "Retained Reminders result disagrees with marker") } }
            if row[2] != "intent_recorded" {
                let terminalEvents: Set<String> = row[2] == "applied" ? ["write_applied"] : row[2] == "unknown" ? ["write_unknown", "recovered_unknown"] : row[2] == "not_applied" ? ["write_not_applied"] : ["user_reconciliation"]
                let terminals = audits[nonce]?.filter { terminalEvents.contains($0["event"].string ?? "") } ?? []
                guard terminals.count == 1, terminals[0]["payload"]["minimal_digest"] == .string(digest(try minimal.data())), try (result == nil || terminals[0]["payload"]["detail_digest"] == .string(digest(result!.data()))) else { throw CoreError("state_corrupt", "Reminder terminal audit binding failed") }
            }
            if row[2] == "not_applied" {
                let evidence: JSON = .object(["version": .int(1), "provider_mutation": .string("not_entered")])
                let matches = audits[nonce]?.filter { $0["event"] == .string("write_not_applied") && $0["approval_source"] == .string("chatgpt_host_policy") && $0["approval_evidence"] == .string("not_provided") } ?? []
                guard Set(minimal.object?.keys.map { $0 } ?? []) == Self.nonExecutionKeys, result == nil || Set(result!.object?.keys.map { $0 } ?? []) == Self.nonExecutionKeys, minimal["message"] == .string(Self.nonExecutionMessage), minimal["audit_sequence"] == intent[0]["sequence"], minimal["action"] == marker["action"], minimal["execution_evidence"] == evidence, WriteDiagnostic.valid(minimal["diagnostic"], preEntryOnly: true), matches.count == 1, matches[0]["payload"]["action"] == marker["action"], matches[0]["payload"]["execution_evidence"] == evidence, matches[0]["payload"]["diagnostic"] == minimal["diagnostic"], matches[0]["payload"]["detail_digest"] == .string(digest(try minimal.data())), (matches[0]["sequence"].integer ?? 0) > (intent[0]["sequence"].integer ?? 0) else { throw CoreError("state_corrupt", "Native Reminders non-entry proof is invalid") }
                validated[nonce] = digest(Data(row[3].utf8))
            }
        }
        try validateAssessments(audits: audits)
        for table in ["details", "execution_keys", "quota"] {
            guard try rows("SELECT nonce FROM " + table + " WHERE nonce NOT IN (SELECT nonce FROM executions)").isEmpty else { throw CoreError("state_corrupt", "Orphan reminder history record") }
        }
        provenNonExecution = validated
    }
}
