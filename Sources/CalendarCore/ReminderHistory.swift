// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit

extension ReminderBroker {
    static let reconciliationKeys: Set<String> = ["version", "domain", "nonce", "issued_at", "expires_at", "installation_id", "credential_generation", "key_id", "source", "assessment", "limitations"]
    static let reconciliationLimitations: JSON = .array([
        .string("This records a user assessment of the earlier outcome; it is not native provider verification or proof of a fresh human confirmation."),
        .string("No reminder is created, changed, deleted, retried, or restored by this journal assessment."),
        .string("The original nonce, unknown result, quota charges, and replay protection remain retained; this assessment does not enable automatic recovery.")])
    func storedChange(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["change_id"], required: ["change_id"])
        guard let row = try state.execution(uuid(a.string("change_id"))) else { throw CoreError("change_missing", "Reminder change is not recorded") }
        return .object(["change_id": .string(row.nonce), "state": .string(row.state), "details_available": .bool(row.detailsAvailable), "payload": row.detailsAvailable ? row.payload : .null, "result": row.result, "message": .string(row.detailsAvailable ? "Retained reminder change; user assessments are not provider verification" : "Private reminder details expired; permanent nonce, outcome, audit and quota markers remain")])
    }
    func history(_ arguments: JSON, unresolved: Bool) throws -> JSON {
        let allowed: Set<String> = unresolved ? ["limit", "cursor"] : ["limit", "cursor", "include_expired", "list_id", "action", "state"]
        let a = try Arguments(arguments, allowed: allowed), limit = a.values["limit"]?.integer ?? 50
        guard (1...100).contains(limit), a.values["limit"] == nil || a.values["limit"]?.integer != nil,
              a.values["include_expired"] == nil || a.values["include_expired"]?.boolean != nil else { throw CoreError("invalid_arguments", "Invalid reminder history limit or retention filter") }
        let includeExpired = a.values["include_expired"]?.boolean ?? false
        var filters: [String: JSON] = ["unresolved": .bool(unresolved), "include_expired": .bool(includeExpired)]
        for key in ["list_id", "action", "state"] where a.values[key] != nil {
            let text = try a.string(key)
            if key == "list_id" { _ = try uuid(text) }
            if key == "action" { guard ["create", "modify", "complete", "reopen", "delete"].contains(text) else { throw CoreError("invalid_arguments", "Invalid reminder history action") } }
            if key == "state" { guard ["applied", "unknown", "intent_recorded", "not_applied", "reconciled"].contains(text) else { throw CoreError("invalid_arguments", "Invalid reminder history state") } }
            filters[key] = .string(text)
        }
        let filter = JSON.object(filters); var cutoff = Int(try state.rows("SELECT COALESCE(MAX(rowid),0) FROM executions")[0][0])! + 1
        if let cursor = a.values["cursor"] {
            guard let text = cursor.string, let data = Data(base64Encoded: text), data.count <= 4096 else { throw CoreError("invalid_cursor", "Invalid reminder history cursor") }
            let wrapper = try JSON.parse(data); _ = try Arguments(wrapper, allowed: ["value", "tag"], required: ["value", "tag"])
            let value = wrapper["value"]
            _ = try Arguments(value, allowed: ["domain", "installation_id", "filters", "before"], required: ["domain", "installation_id", "filters", "before"])
            guard value["domain"] == .string("reminder_history"), value["installation_id"] == .string(try state.required("installation_id")), value["filters"] == filter, let before = value["before"].integer, before > 0, let tagText = wrapper["tag"].string, let tag = Data(base64Encoded: tagText), HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: try authData(value, domain: "reminder_history"), using: try state.signingKey()) else { throw CoreError("invalid_cursor", "Reminder history cursor does not match its filters") }; cutoff = before
        }
        var candidates: [(Int, JSON)] = []
        var scan = cutoff
        while candidates.count <= limit {
            let retainedFilter = !unresolved && !includeExpired ? " AND d.expired=0" : ""
            let stateFilter = unresolved ? " AND e.state IN ('unknown','intent_recorded')" : ""
            let page = try state.rows("SELECT e.rowid,e.nonce,e.marker,e.state,e.created,d.expired FROM executions e JOIN details d USING(nonce) WHERE e.rowid<?" + retainedFilter + stateFilter + " ORDER BY e.rowid DESC LIMIT 256", [String(scan)])
            if page.isEmpty { break }
            for row in page {
                scan = Int(row[0])!
                let marker = try JSON.parse(Data(row[2].utf8))
                if let list = filters["list_id"], marker["list_id"] != list { continue }
                if let action = filters["action"], marker["action"] != action { continue }
                if let state = filters["state"], .string(row[3]) != state { continue }
                candidates.append((scan, .object(["change_id": .string(row[1]), "action": marker["action"], "state": .string(row[3]), "list_id": marker["list_id"], "created_at": .string(row[4]), "details_available": .bool(row[5] == "0"), "source_change_id": marker["source_change_id"]])))
                if candidates.count > limit { break }
            }
            if page.count < 256 { break }
        }
        let selected = Array(candidates.prefix(limit)); var next: JSON = .null
        if candidates.count > limit, let last = selected.last {
            let value: JSON = .object(["domain": .string("reminder_history"), "installation_id": .string(try state.required("installation_id")), "filters": filter, "before": .int(last.0)])
            let tag = HMAC<SHA256>.authenticationCode(for: try authData(value, domain: "reminder_history"), using: try state.signingKey())
            next = .string(try JSON.object(["value": value, "tag": .string(Data(tag).base64EncodedString())]).data().base64EncodedString())
        }
        return .object(["changes": .array(selected.map(\.1)), "next_cursor": next])
    }
    func preflightReconciliation(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["change_id", "outcome", "evidence"], required: ["change_id", "outcome", "evidence"]), id = try uuid(a.string("change_id")), outcome = try a.string("outcome"), evidence = try a.string("evidence")
        guard ["applied", "not_applied"].contains(outcome), !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, evidence.unicodeScalars.count <= 2000 else { throw CoreError("invalid_reconciliation", "An explicit user outcome assessment and bounded evidence are required") }
        guard let source = try state.execution(id), source.state == "unknown", source.detailsAvailable else { throw CoreError("reconciliation_ineligible", "Assessment requires an unchanged retained unknown reminder outcome") }
        var envelope = try base(domain: "reminders_reconciliation")
        envelope.merge(["source": .object(["change_id": .string(id), "payload_digest": .string(digest(try source.payload.data())), "result_digest": .string(digest(try source.result.data())), "payload": source.payload, "result": source.result]), "assessment": .object(["outcome": .string(outcome), "evidence": .string(evidence)]), "limitations": Self.reconciliationLimitations]) { _, new in new }
        return .object(["preview": try sign(.object(envelope), domain: "reminders_reconciliation", assessment: true)])
    }
    func commitReconciliation(_ arguments: JSON) throws -> JSON {
        let envelope = try authenticate(arguments, keys: Self.reconciliationKeys, domain: "reminders_reconciliation", assessment: true)
        let nonce = envelope["nonce"].string!, hash = digest(try envelope.data())
        if let prior = try state.receipt(nonce: nonce, digest: hash) { try state.recordObservation(replayed: true, operation: "commit_reminder_reconciliation", now: now()); return prior }
        try fresh(envelope)
        let source = envelope["source"], assessment = envelope["assessment"]
        _ = try Arguments(source, allowed: ["change_id", "payload_digest", "result_digest", "payload", "result"], required: ["change_id", "payload_digest", "result_digest", "payload", "result"])
        _ = try Arguments(assessment, allowed: ["outcome", "evidence"], required: ["outcome", "evidence"])
        _ = try uuid(source["change_id"].string ?? "")
        guard envelope["limitations"] == Self.reconciliationLimitations, ["applied", "not_applied"].contains(assessment["outcome"].string ?? ""), let evidence = assessment["evidence"].string, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, evidence.unicodeScalars.count <= 2000 else { throw CoreError("invalid_reconciliation", "Reminder assessment or limitations changed") }
        return try state.assess(envelope, now: now())
    }
}
