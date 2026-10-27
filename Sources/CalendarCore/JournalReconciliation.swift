// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit

extension StateStore {
    func installReconciliationStorage() throws {
        try transaction {
            try execute("CREATE TABLE IF NOT EXISTS reconciliation_claims(nonce TEXT PRIMARY KEY,source_nonce TEXT NOT NULL UNIQUE,preview_digest TEXT NOT NULL,receipt TEXT NOT NULL,created TEXT NOT NULL)")
            try execute("CREATE TRIGGER IF NOT EXISTS reconciliation_no_update BEFORE UPDATE ON reconciliation_claims BEGIN SELECT RAISE(ABORT,'immutable reconciliation claim'); END")
            try execute("CREATE TRIGGER IF NOT EXISTS reconciliation_no_delete BEFORE DELETE ON reconciliation_claims BEGIN SELECT RAISE(ABORT,'immutable reconciliation claim'); END")
            try execute("CREATE TRIGGER IF NOT EXISTS reconciliation_nonce_disjoint BEFORE INSERT ON reconciliation_claims WHEN EXISTS(SELECT 1 FROM executions WHERE nonce=NEW.nonce) BEGIN SELECT RAISE(ABORT,'nonce namespace collision'); END")
            try execute("CREATE TRIGGER IF NOT EXISTS execution_nonce_disjoint BEFORE INSERT ON executions WHEN EXISTS(SELECT 1 FROM reconciliation_claims WHERE nonce=NEW.nonce) BEGIN SELECT RAISE(ABORT,'nonce namespace collision'); END")
        }
    }
    func reconciliationReceipt(nonce: String, previewDigest: String) throws -> JSON? {
        guard let row = try rows("SELECT preview_digest,receipt FROM reconciliation_claims WHERE nonce=?", [nonce]).first else { return nil }
        guard row[0] == previewDigest else { throw CoreError("nonce_conflict", "Reconciliation nonce already binds another preview") }
        return try JSON.parse(Data(row[1].utf8))
    }
    func reconcileUserAssessment(envelope: JSON, now: Date) throws -> JSON {
        let nonce = envelope["nonce"].string!, source = envelope["source"], id = source["change_id"].string!, assessment = envelope["assessment"]
        let previewDigest = digest(try envelope.data())
        return try transaction {
            if let receipt = try reconciliationReceipt(nonce: nonce, previewDigest: previewDigest) { return receipt }
            guard try execution(nonce) == nil else { throw CoreError("nonce_conflict", "Nonce already belongs to a Calendar execution") }
            guard try rows("SELECT nonce FROM reconciliation_claims WHERE source_nonce=?", [id]).isEmpty,
                  let previous = try execution(id), previous.state == "unknown",
                  previous.payload == source["payload"], previous.result == source["result"],
                  source["payload_digest"] == .string(digest(try previous.payload.data())),
                  source["result_digest"] == .string(digest(try previous.result.data())) else {
                throw CoreError("stale_reconciliation", "The retained unknown source changed; inspect its current outcome")
            }
            let result: JSON = .object(["nonce": .string(id), "state": .string("reconciled"), "outcome": assessment["outcome"], "evidence": assessment["evidence"], "previous_result": previous.result, "resolution_source": .string("user_assessment"), "verification": .string("not_performed"), "reconciliation_nonce": .string(nonce)])
            try storeResult(nonce: id, state: "reconciled", result: result)
            let sequence = try appendInsideTransaction(event: "user_reconciliation", nonce: id, payload: result)
            let receipt: JSON = .object(["reconciliation_nonce": .string(nonce), "change_id": .string(id), "state": .string("reconciled"), "outcome": assessment["outcome"], "resolution_source": .string("user_assessment"), "verification": .string("not_performed"), "audit_sequence": .int(sequence)])
            try execute("INSERT INTO reconciliation_claims(nonce,source_nonce,preview_digest,receipt,created) VALUES(?,?,?,?,?)", [nonce, id, previewDigest, try receipt.text(), iso(now)])
            return receipt
        }
    }
}

extension Broker {
    static let reconciliationLimitations: JSON = .array([
        .string("This records a user assessment of the earlier outcome; it is not native provider verification or proof of a fresh human confirmation."),
        .string("This changes only the integration journal. It does not change Calendar data, retry the earlier operation, or compensate for it."),
        .string("The original nonce, unknown result and quota charges remain retained under existing retention rules. Resolution may unblock related changes but does not make this execution eligible for automatic rollback.")])
    static let reconciliationCapabilities: JSON = .object(["version": .int(1), "storage_version": .int(6), "preview_version": .int(1), "kind": .string("journal_reconciliation"), "user_assessment": .bool(true), "automatic_verification": .bool(false), "calendar_mutation": .bool(false), "outcomes": .array([.string("applied"), .string("not_applied")]), "max_evidence_length": .int(2000), "commit_tools": .array([.string("commit_reconciliation")])])
    // Separate cryptographic domain from every Calendar execution preview and cursor.
    func reconciliationAuthentication(_ value: JSON, domain: String) throws -> Data {
        Data(("calendar-mcp:" + domain + ":v1\0").utf8) + (try value.data())
    }
    func listUnresolvedChanges(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["limit", "cursor"])
        let limit = a.values["limit"] == nil ? 50 : a.values["limit"]?.integer ?? 0
        guard (1...100).contains(limit) else { throw CoreError("invalid_arguments", "Unresolved limit must be 1 through 100") }
        var cutoff = Int(try state.rows("SELECT COALESCE(MAX(rowid),0) FROM executions").first![0])!, after = Int.max
        if let cursor = a.values["cursor"] {
            guard let encoded = cursor.string, encoded.utf8.count <= 4096, let bytes = Data(base64Encoded: encoded) else { throw CoreError("invalid_cursor", "Invalid unresolved cursor") }
            let wrapper = try JSON.parse(bytes)
            _ = try Arguments(wrapper, allowed: ["body", "tag"], required: ["body", "tag"])
            let body = wrapper["body"]
            _ = try Arguments(body, allowed: ["version", "kind", "installation_id", "credential_generation", "key_id", "cutoff", "after"], required: ["version", "kind", "installation_id", "credential_generation", "key_id", "cutoff", "after"])
            guard body["version"] == .int(1), body["kind"] == .string("unresolved_changes"),
                  body["installation_id"] == .string(try requiredMetadata("installation_id")), body["credential_generation"] == .string(try requiredMetadata("credential_generation")), body["key_id"] == .string(try requiredMetadata("key_id")),
                  let tag = wrapper["tag"].string.flatMap({ Data(base64Encoded: $0) }), tag.count == 32,
                  HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: try reconciliationAuthentication(body, domain: "unresolved_cursor"), using: try signingKey()),
                  let c = body["cutoff"].integer, c >= 0, let last = body["after"].integer, last > 0, last <= c else { throw CoreError("invalid_cursor", "Unresolved cursor binding failed") }
            cutoff = c; after = last
        }
        let rows = try state.rows("SELECT nonce,payload,created,rowid FROM executions WHERE state='unknown' AND rowid<=? AND rowid<? ORDER BY rowid DESC LIMIT ?", [String(cutoff), String(after), String(limit + 1)])
        let page = Array(rows.prefix(limit))
        let changes = try page.map { row -> JSON in
            let marker = try JSON.parse(Data(row[1].utf8))
            return .object(["change_id": .string(row[0]), "action": marker["action"], "scope": marker["scope"], "created_at": .string(row[2]), "state": .string("unknown"), "calendar_id": marker["calendar_id"], "details_available": .bool(true)])
        }
        var cursor: JSON = .null
        if rows.count > limit, let last = page.last {
            let body: JSON = .object(["version": .int(1), "kind": .string("unresolved_changes"), "installation_id": .string(try requiredMetadata("installation_id")), "credential_generation": .string(try requiredMetadata("credential_generation")), "key_id": .string(try requiredMetadata("key_id")), "cutoff": .int(cutoff), "after": .int(Int(last[3])!)])
            let tag = HMAC<SHA256>.authenticationCode(for: try reconciliationAuthentication(body, domain: "unresolved_cursor"), using: try signingKey())
            cursor = .string(try JSON.object(["body": body, "tag": .string(Data(tag).base64EncodedString())]).data().base64EncodedString())
        }
        return .object(["changes": .array(changes), "next_cursor": cursor])
    }
    func reconciliationAssessment(_ value: JSON) throws {
        let a = try Arguments(value, allowed: ["outcome", "evidence"], required: ["outcome", "evidence"])
        guard ["applied", "not_applied"].contains(try a.string("outcome")), let evidence = value["evidence"].string,
              !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, evidence.unicodeScalars.count <= 2000 else { throw CoreError("invalid_reconciliation", "Provide applied or not_applied and nonblank evidence of at most 2000 Unicode scalars") }
    }
    func preflightReconciliation(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["change_id", "outcome", "evidence"], required: ["change_id", "outcome", "evidence"])
        guard let id = UUID(uuidString: try a.string("change_id"))?.uuidString else { throw CoreError("invalid_arguments", "Invalid change ID") }
        let assessment: JSON = .object(["outcome": arguments["outcome"], "evidence": arguments["evidence"]]); try reconciliationAssessment(assessment)
        guard let source = try state.execution(id), source.state == "unknown", source.payload["storage_version"] == .null else { throw CoreError("invalid_reconciliation", "Only retained unknown executions can be assessed") }
        let issued = now()
        let envelope: JSON = .object(["version": .int(1), "kind": .string("journal_reconciliation"), "action": .string("reconcile"), "nonce": .string(UUID().uuidString), "issued_at": .string(iso(issued)), "expires_at": .string(iso(issued.addingTimeInterval(600))), "installation_id": .string(try requiredMetadata("installation_id")), "credential_generation": .string(try requiredMetadata("credential_generation")), "key_id": .string(try requiredMetadata("key_id")), "source": .object(["change_id": .string(id), "payload_digest": .string(digest(try source.payload.data())), "result_digest": .string(digest(try source.result.data())), "payload": source.payload, "result": source.result]), "assessment": assessment, "limitations": Self.reconciliationLimitations])
        guard try envelope.data().count <= 524_288 else { throw CoreError("preview_too_large", "Journal assessment exceeds 512 KiB") }
        let tag = HMAC<SHA256>.authenticationCode(for: try reconciliationAuthentication(envelope, domain: "journal_reconciliation"), using: try signingKey())
        let preview: JSON = .object(["envelope": envelope, "authentication_tag": .string(Data(tag).base64EncodedString())])
        // Leave room for the complete commit wrapper within the existing native wire cap.
        let request: JSON = .object(["op": .string("commit_reconciliation"), "arguments": .object(["preview": preview])])
        guard try request.data().count <= 524_288 else { throw CoreError("preview_too_large", "Complete journal assessment exceeds the native request bound") }
        return .object(["preview": preview])
    }
    func commitReconciliation(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["preview"], required: ["preview"])
        let p = try Arguments(a.values["preview"]!, allowed: ["envelope", "authentication_tag"], required: ["envelope", "authentication_tag"])
        let envelope = p.values["envelope"]!
        let keys: Set<String> = ["version", "kind", "action", "nonce", "issued_at", "expires_at", "installation_id", "credential_generation", "key_id", "source", "assessment", "limitations"]
        _ = try Arguments(envelope, allowed: keys, required: keys)
        guard try envelope.data().count <= 524_288, envelope["version"] == .int(1), envelope["kind"] == .string("journal_reconciliation"), envelope["action"] == .string("reconcile"),
              envelope["installation_id"] == .string(try requiredMetadata("installation_id")), envelope["credential_generation"] == .string(try requiredMetadata("credential_generation")), envelope["key_id"] == .string(try requiredMetadata("key_id")),
              let tag = Data(base64Encoded: try p.string("authentication_tag")), tag.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: try reconciliationAuthentication(envelope, domain: "journal_reconciliation"), using: try signingKey()),
              let nonce = envelope["nonce"].string, UUID(uuidString: nonce)?.uuidString == nonce else { throw CoreError("invalid_preview", "Journal assessment integrity or binding failed") }
        let previewDigest = digest(try envelope.data())
        if let receipt = try state.reconciliationReceipt(nonce: nonce, previewDigest: previewDigest) {
            try state.recordCommitObservation(replayed: true, operation: "commit_reconciliation", now: now())
            return receipt
        }
        _ = try Arguments(envelope["source"], allowed: ["change_id", "payload_digest", "result_digest", "payload", "result"], required: ["change_id", "payload_digest", "result_digest", "payload", "result"])
        guard let id = envelope["source"]["change_id"].string, UUID(uuidString: id)?.uuidString == id,
              envelope["limitations"] == Self.reconciliationLimitations else { throw CoreError("invalid_preview", "Invalid journal assessment source or limitations") }
        try reconciliationAssessment(envelope["assessment"])
        guard let issued = envelope["issued_at"].string, let expires = envelope["expires_at"].string else { throw CoreError("invalid_preview", "Invalid journal assessment times") }
        let start = try parseDate(issued), end = try parseDate(expires), current = now()
        guard start <= current.addingTimeInterval(0.001), end > current, abs(end.timeIntervalSince(start) - 600) <= 0.001 else { throw CoreError("preview_expired", "Journal assessment expired or not yet valid; prepare a fresh preview") }
        return try state.reconcileUserAssessment(envelope: envelope, now: current)
    }
}
