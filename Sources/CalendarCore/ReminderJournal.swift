// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

extension ReminderStateStore {
    static let observationBuckets = Set(["replayed", "rejected"].flatMap { prefix in ["create", "modify", "complete", "reopen", "delete", "rollback", "reconciliation", "other"].map { prefix + ":" + $0 } })
    func validateObservationSnapshot(_ value: JSON) throws {
        guard let rows = value.array, rows.count <= Self.observationBuckets.count else { throw CoreError("audit_corrupt", "Invalid reminder observation checkpoint") }
        var seen: Set<String> = []
        for row in rows {
            guard let object = row.object, Set(object.keys) == ["bucket", "count"], let bucket = row["bucket"].string, Self.observationBuckets.contains(bucket), seen.insert(bucket).inserted, let text = row["count"].string, let count = Int(text), count >= 0, String(count) == text else { throw CoreError("audit_corrupt", "Invalid reminder observation checkpoint") }
        }
    }
    func validateObservations(checkpoint snapshot: JSON? = nil) throws {
        let expected = Dictionary(uniqueKeysWithValues: (snapshot?.array ?? []).map { ($0["bucket"].string!, Int($0["count"].string!)!) })
        var seen: Set<String> = []
        for row in try rows("SELECT bucket,count,checkpointed FROM observations") {
            guard Self.observationBuckets.contains(row[0]), let count = Int(row[1]), let checkpoint = Int(row[2]), count >= checkpoint, checkpoint >= 0 else { throw CoreError("state_corrupt", "Invalid reminder observation counts") }
            seen.insert(row[0])
            if snapshot != nil { guard checkpoint == (expected[row[0]] ?? 0) else { throw CoreError("state_corrupt", "Reminder observation checkpoint disagrees with audit") } }
        }
        guard Set(expected.keys).isSubset(of: seen) else { throw CoreError("state_corrupt", "Missing reminder observation bucket") }
    }
    func recordObservation(replayed: Bool, operation: String, now: Date) throws {
        let known = ["create", "modify", "complete", "reopen", "delete", "rollback", "reconciliation"]
        let short = String(operation.replacingOccurrences(of: "commit_reminder_", with: ""))
        let bucket = (replayed ? "replayed:" : "rejected:") + (known.contains(short) ? short : "other")
        try transaction {
            try validateObservations()
            if let row = try rows("SELECT count FROM observations WHERE bucket=?", [bucket]).first {
                guard let count = Int(row[0]), count >= 0, count < Int.max else { throw CoreError("audit_unavailable", "Reminders observation counter exhausted") }
                try execute("UPDATE observations SET count=? WHERE bucket=?", [String(count + 1), bucket])
            } else { try execute("INSERT INTO observations VALUES(?,1,0)", [bucket]) }
            let previous = try metadata("observation_clock").map(parseDate) ?? now, effective = max(previous, now)
            try setMetadata("observation_clock", iso(effective))
            let checkpoint = try metadata("observation_checkpoint").map(parseDate) ?? effective
            if try metadata("observation_checkpoint") == nil { try setMetadata("observation_checkpoint", iso(effective)) }
            if effective.timeIntervalSince(checkpoint) >= 3600 {
                let dirty = try rows("SELECT bucket,count FROM observations WHERE count<>checkpointed ORDER BY bucket")
                if !dirty.isEmpty {
                    let snapshot = try rows("SELECT bucket,count FROM observations ORDER BY bucket").map { JSON.object(["bucket": .string($0[0]), "count": .string($0[1])]) }
                    _ = try appendInside("observation_checkpoint", nonce: nil, payload: .object(["observations": .array(snapshot)]), origin: "native_maintenance")
                    try execute("UPDATE observations SET checkpointed=count")
                }
                try setMetadata("observation_checkpoint", iso(effective))
            }
        }
    }
    func receipt(nonce: String, digest: String) throws -> JSON? {
        guard let row = try rows("SELECT digest,receipt FROM assessments WHERE nonce=?", [nonce]).first else { return nil }
        guard row[0] == digest else { throw CoreError("nonce_conflict", "Reminder assessment nonce binds another exact preview") }
        return try JSON.parse(Data(row[1].utf8))
    }
    func assess(_ envelope: JSON, now: Date) throws -> JSON {
        let nonce = envelope["nonce"].string!, source = envelope["source"], id = source["change_id"].string!, assessment = envelope["assessment"]
        let previewDigest = digest(try envelope.data())
        return try transaction {
            if let prior = try receipt(nonce: nonce, digest: previewDigest) { return prior }
            guard try execution(nonce) == nil, try rows("SELECT nonce FROM assessments WHERE source_nonce=?", [id]).isEmpty,
                  let previous = try execution(id), previous.state == "unknown", previous.detailsAvailable,
                  previous.payload == source["payload"], previous.result == source["result"],
                  source["payload_digest"] == .string(digest(try previous.payload.data())), source["result_digest"] == .string(digest(try previous.result.data())),
                  let raw = try rows("SELECT key FROM execution_keys WHERE nonce=?", [id]).first, let key = Data(base64Encoded: raw[0]) else { throw CoreError("stale_reconciliation", "Reminder unknown source changed; inspect the original change") }
            let result: JSON = .object(["nonce": .string(id), "state": .string("reconciled"), "action": previous.marker["action"], "outcome": assessment["outcome"], "evidence": assessment["evidence"], "previous_result": previous.result, "resolution_source": .string("user_assessment"), "verification": .string("not_performed"), "reconciliation_nonce": .string(nonce), "assessment_digest": .string(previewDigest)])
            try execute("UPDATE details SET result_cipher=? WHERE nonce=?", [try crypt(result, key: key, nonce: id, field: "result_cipher"), id])
            try execute("UPDATE executions SET state='reconciled',result=? WHERE nonce=? AND state='unknown'", [try minimal(result, nonce: id, state: "reconciled").text(), id])
            let sequence = try appendInside("user_reconciliation", nonce: id, payload: result)
            let receipt: JSON = .object(["reconciliation_nonce": .string(nonce), "change_id": .string(id), "state": .string("reconciled"), "outcome": assessment["outcome"], "resolution_source": .string("user_assessment"), "verification": .string("not_performed"), "audit_sequence": .int(sequence)])
            try execute("INSERT INTO assessments VALUES(?,?,?,?)", [nonce, id, previewDigest, try receipt.text()]); return receipt
        }
    }
    func validateAssessments(audits: [String: [JSON]]) throws {
        let keys: Set<String> = ["reconciliation_nonce", "change_id", "state", "outcome", "resolution_source", "verification", "audit_sequence"]
        var sources: Set<String> = []
        for row in try rows("SELECT nonce,source_nonce,digest,receipt FROM assessments") {
            let receipt = try JSON.parse(Data(row[3].utf8))
            let entries = audits[row[1]]?.filter { $0["event"] == .string("user_reconciliation") } ?? []
            guard UUID(uuidString: row[0])?.uuidString == row[0], row[2].range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  Set(receipt.object?.keys.map { $0 } ?? []) == keys, receipt["reconciliation_nonce"] == .string(row[0]), receipt["change_id"] == .string(row[1]), receipt["state"] == .string("reconciled"), ["applied", "not_applied"].contains(receipt["outcome"].string ?? ""), receipt["resolution_source"] == .string("user_assessment"), receipt["verification"] == .string("not_performed"),
                  let source = try execution(row[1]), source.state == "reconciled", source.result["reconciliation_nonce"] == .string(row[0]), source.result["outcome"] == receipt["outcome"], source.result["assessment_digest"] == .string(row[2]), sources.insert(row[1]).inserted,
                  entries.count == 1, entries[0]["sequence"] == receipt["audit_sequence"], entries[0]["approval_source"] == .string("chatgpt_host_policy"), entries[0]["payload"]["reconciliation_nonce"] == .string(row[0]), entries[0]["payload"]["outcome"] == receipt["outcome"], entries[0]["payload"]["verification"] == .string("not_performed"), entries[0]["payload"]["assessment_digest"] == .string(row[2]) else { throw CoreError("state_corrupt", "Reminder user-assessment receipt or audit binding failed") }
            if source.detailsAvailable {
                guard entries[0]["payload"]["detail_digest"] == .string(digest(try source.result.data())), source.result["previous_result"]["nonce"] == .string(row[1]), source.result["previous_result"]["state"] == .string("unknown"), source.result["previous_result"]["action"] == source.marker["action"], let evidence = source.result["evidence"].string, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, evidence.unicodeScalars.count <= 2000 else { throw CoreError("state_corrupt", "Reminder retained assessment source is invalid") }
            }
        }
        guard Set(try rows("SELECT nonce FROM executions WHERE state='reconciled'").map { $0[0] }) == sources else { throw CoreError("state_corrupt", "Reminder assessment receipt is missing") }
    }
    func rebindReminder(id: String, nativeID: String, listNativeID: String) throws {
        _ = try resolve(id, kind: "reminder")
        guard try rows("SELECT id FROM identities WHERE kind='reminder' AND native_id=? AND list_native_id=? AND id<>?", [nativeID, listNativeID, id]).isEmpty else { throw CoreError("identity_ambiguous", "Saved reminder identity is already bound") }
        try execute("UPDATE identities SET native_id=?,list_native_id=? WHERE id=? AND kind='reminder'", [nativeID, listNativeID, id])
    }
}
