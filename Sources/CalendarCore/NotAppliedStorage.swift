// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

extension StateStore {
    static let notAppliedMessage = "The provider mutation was not entered. Request a fresh preview and confirmation to try the intended change again; this nonce stays consumed and its quota charge is retained"
    static var notEnteredEvidence: JSON { .object(["version": .int(1), "provider_mutation": .string("not_entered")]) }
    /// Validate the durable minimal proof. Metadata state alone never establishes safety.
    func notAppliedProof(nonce: String, marker: JSON, result: JSON) throws -> JSON {
        let required: Set<String> = ["storage_version", "nonce", "state", "action", "audit_sequence", "execution_evidence", "diagnostic"]
        guard let values = result.object, required.isSubset(of: Set(values.keys)), Set(values.keys).isSubset(of: required.union(["details_expired"])),
              result["details_expired"] == .null || result["details_expired"] == .bool(true),
              let sequence = result["audit_sequence"].integer, sequence > 0,
              UUID(uuidString: nonce) != nil, marker["storage_version"] == .int(2), result["storage_version"] == .int(2),
              result["nonce"] == .string(nonce), result["state"] == .string("not_applied"),
              let action = marker["action"].string, ["create", "modify", "delete"].contains(action), result["action"] == .string(action),
              result["execution_evidence"] == Self.notEnteredEvidence,
              WriteDiagnostic.valid(result["diagnostic"], preEntryOnly: true) else { throw CoreError("state_corrupt", "Native non-execution proof is invalid; writes disabled") }
        return .object(["storage_version": .int(2), "nonce": .string(nonce), "state": .string("not_applied"), "action": .string(action), "audit_sequence": .int(sequence), "execution_evidence": result["execution_evidence"], "diagnostic": result["diagnostic"]])
    }
    /// Called from the existing audit-chain scan before expiry, recovery or serving.
    func validateNotAppliedHistory(_ auditProofs: [String: JSON]) throws {
        var verified: [String: String] = [:]
        for row in try rows("SELECT nonce,payload,result FROM executions WHERE state='not_applied'") {
            guard try metadata("recovery_storage_version") == "7" else { throw CoreError("state_corrupt", "Non-execution state requires the current writer floor") }
            let marker = try JSON.parse(Data(row[1].utf8)), result = try JSON.parse(Data(row[2].utf8))
            let proof = try notAppliedProof(nonce: row[0], marker: marker, result: result)
            if let retained = try secret(nonce: row[0], column: "result_cipher") {
                let keys: Set<String> = ["nonce", "state", "action", "audit_sequence", "execution_evidence", "diagnostic", "message"]
                guard let values = retained.object, Set(values.keys) == keys,
                      retained["nonce"] == .string(row[0]), retained["state"] == .string("not_applied"),
                      retained["action"] == marker["action"], retained["message"] == .string(Self.notAppliedMessage) else { throw CoreError("state_corrupt", "Retained non-execution identity or shape is invalid") }
                guard try notAppliedProof(nonce: row[0], marker: marker, result: minimalResult(nonce: row[0], state: "not_applied", result: retained)) == proof else { throw CoreError("state_corrupt", "Retained non-execution result differs from its minimal proof") }
            }
            guard auditProofs[row[0]] == proof else { throw CoreError("audit_corrupt", "Native non-execution outcome lacks its exact chained proof") }
            verified[row[0]] = digest(try proof.data())
        }
        guard Set(verified.keys) == Set(auditProofs.keys) else { throw CoreError("audit_corrupt", "Native non-execution audit does not match its journal state") }
        provenNotApplied = verified
    }
    func isProvenNotApplied(_ row: [String]) throws -> Bool {
        guard row[2] == "not_applied" else { return false }
        let proof = try notAppliedProof(nonce: row[0], marker: JSON.parse(Data(row[1].utf8)), result: JSON.parse(Data(row[3].utf8)))
        guard provenNotApplied[row[0]] == digest(try proof.data()) else { throw CoreError("state_corrupt", "Non-execution proof changed after validation") }
        return true
    }
    func finishNotApplied(nonce: String, action: String, failure: ProviderMutationFailure, sequence: Int) throws -> JSON {
        guard failure.provesNotEntered else { throw CoreError("state_corrupt", "Provider non-entry proof is required") }
        let result: JSON = .object(["nonce": .string(nonce), "state": .string("not_applied"), "action": .string(action), "audit_sequence": .int(sequence), "execution_evidence": Self.notEnteredEvidence, "diagnostic": failure.diagnostic.json, "message": .string(Self.notAppliedMessage)])
        let proof = try transaction {
            guard let row = try rows("SELECT payload,state FROM executions WHERE nonce=?", [nonce]).first, row[1] == "intent_recorded" else { throw CoreError("audit_unavailable", "Only an active durable intent can record native non-execution") }
            let minimal = minimalResult(nonce: nonce, state: "not_applied", result: result)
            let proof = try notAppliedProof(nonce: nonce, marker: JSON.parse(Data(row[0].utf8)), result: minimal)
            try storeResult(nonce: nonce, state: "not_applied", result: result)
            _ = try appendInsideTransaction(event: "write_not_applied", nonce: nonce, payload: result)
            return proof
        }
        // Cache only committed evidence. Rollback must never make a row nonblocking.
        provenNotApplied[nonce] = digest(try proof.data())
        return result
    }
}
