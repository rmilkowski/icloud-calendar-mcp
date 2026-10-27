// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit


public final class ReminderBroker: @unchecked Sendable {
    public let state: ReminderStateStore
    let backend: any ReminderBackend
    let now: () -> Date
    let lock = NSLock()
    public static let capabilities: JSON = .object(["version": .int(1), "storage_version": .int(1), "preview_version": .int(1), "nonrecurring": .bool(true), "recovery": .bool(true), "reconciliation": .bool(true), "max_selection": .int(1)])
    public static let operations: Set<String> = ["reminders_capabilities", "list_reminder_lists", "query_reminders", "get_reminder", "preflight_reminder_change", "commit_reminder_create", "commit_reminder_modify", "commit_reminder_complete", "commit_reminder_reopen", "commit_reminder_delete", "get_reminder_change_status", "list_reminder_changes", "get_stored_reminder_change", "preflight_reminder_rollback", "commit_reminder_rollback", "list_unresolved_reminder_changes", "preflight_reminder_reconciliation", "commit_reminder_reconciliation"]
    static let fields: Set<String> = ["title", "notes", "priority", "start", "due", "alerts", "completed"]
    static let limitations: JSON = .array([
        .string("Recovery is a new reviewed write and requires retained details, unchanged supported state, and no conflicting later operation."),
        .string("Only supported EventKit reminder fields are covered; tags, subtasks, attachments, assignments, sharing, ordering, and other private app metadata are not restored or verified."),
        .string("Deletion recovery creates a new nonrecurring reminder with a new identity; it does not restore the original object or list relationships.")])
    public init(state: ReminderStateStore, backend: any ReminderBackend, now: @escaping () -> Date = Date.init) { self.state = state; self.backend = backend; self.now = now }
    public func handle(_ request: JSON) -> JSON {
        lock.lock(); defer { lock.unlock() }
        do {
            let r = try Arguments(request, allowed: ["op", "arguments"], required: ["op", "arguments"])
            try state.expire(now: now())
            return .object(["result": try perform(r.string("op"), arguments: r.values["arguments"]!)])
        } catch {
            var failure = error as? CoreError ?? CoreError("reminders_error", "Reminders operation failed safely")
            if let op = request["op"].string, op.hasPrefix("commit_reminder_") {
                do { try state.recordObservation(replayed: false, operation: op, now: now()) } catch { failure = CoreError("audit_unavailable", "Cannot durably account for rejected reminder commit") }
            }
            return .object(["error": .object(["code": .string(failure.code), "message": .string(failure.message)])])
        }
    }
    public func maintainDetails() { lock.lock(); defer { lock.unlock() }; try? state.expire(now: now()) }
    private func perform(_ op: String, arguments: JSON) throws -> JSON {
        switch op {
        case "reminders_capabilities": _ = try Arguments(arguments, allowed: []); return Self.capabilities
        case "list_reminder_lists": _ = try Arguments(arguments, allowed: []); return .object(["lists": .array(try lists().map(\.1))])
        case "get_reminder": let a = try Arguments(arguments, allowed: ["reminder_id"], required: ["reminder_id"]); return .object(["reminder": try view(reminder(a.string("reminder_id")))])
        case "query_reminders": return try query(arguments)
        case "preflight_reminder_change": return try preflight(arguments)
        case "commit_reminder_create", "commit_reminder_modify", "commit_reminder_complete", "commit_reminder_reopen", "commit_reminder_delete": return try commit(arguments, expectedAction: String(op.dropFirst("commit_reminder_".count)), rollback: false)
        case "commit_reminder_rollback": return try commit(arguments, expectedAction: nil, rollback: true)
        case "preflight_reminder_rollback": return try preflightRollback(arguments)
        case "list_reminder_changes": return try history(arguments, unresolved: false)
        case "list_unresolved_reminder_changes": return try history(arguments, unresolved: true)
        case "get_stored_reminder_change": return try storedChange(arguments)
        case "preflight_reminder_reconciliation": return try preflightReconciliation(arguments)
        case "commit_reminder_reconciliation": return try commitReconciliation(arguments)
        case "get_reminder_change_status":
            let a = try Arguments(arguments, allowed: ["nonce"], required: ["nonce"]), nonce = try uuid(a.string("nonce"))
            return try state.execution(nonce)?.result ?? .object(["nonce": .string(nonce), "state": .string("not_received")])
        default: throw CoreError("unknown_operation", "Unsupported Reminders operation")
        }
    }
    func uuid(_ text: String) throws -> String { guard let id = UUID(uuidString: text), id.uuidString == text else { throw CoreError("invalid_arguments", "Use an exact opaque reminder identity") }; return text }
    func lists() throws -> [(ReminderListRecord, JSON)] {
        let records = try backend.lists(); guard records.count <= 200, Set(records.map(\.nativeID)).count == records.count else { throw CoreError("too_many_lists", "Reminder lists exceed the bounded unique inventory") }
        let result = try records.map { record in (record, record.view(id: try state.identity(kind: "list", nativeID: record.nativeID))) }.sorted { $0.1["id"].string! < $1.1["id"].string! }
        guard try JSON.array(result.map(\.1)).data().count <= 393216 else { throw CoreError("lists_too_large", "Reminder list metadata exceeds bounded response size") }; return result
    }
    func view(_ record: ReminderRecord, id: String? = nil) throws -> JSON {
        let list = try state.identity(kind: "list", nativeID: record.listNativeID)
        return try record.view(id: id ?? state.identity(kind: "reminder", nativeID: record.nativeID, listID: record.listNativeID), listID: list)
    }
    func reminder(_ id: String) throws -> ReminderRecord { let binding = try state.resolve(uuid(id), kind: "reminder"); return try backend.get(nativeID: binding.nativeID, listID: binding.listID) }
    func eligible(_ value: ReminderRecord) throws {
        guard value.unsupportedReasons.isEmpty, !value.fields.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.completed == (value.completionDate != nil), value.details["has_recurrence_rules"] != .bool(true), value.details["recurrence_rules"].array?.isEmpty != false else { throw CoreError("unsupported_reminder", "Reminder has unsupported recurrence, components or completion metadata") }
        try ReminderWriteWitness.eligibility(value)
        _ = try value.exactCompletionDate()
        if let alarms = value.details["alarms"].array {
            guard alarms.allSatisfy({ $0["type"].integer == 0 || $0["type"].integer == 1 }) else { throw CoreError("unsupported_alarm", "External-action reminder alarms cannot be mutated") }
        }
    }
    func alarms(_ value: JSON) -> JSON { value["alarms"] == .null ? .array([]) : value["alarms"] }
    func authData(_ envelope: JSON, domain: String) throws -> Data { Data(("calendar-mcp:" + domain + ":v1\0").utf8) + (try envelope.data()) }
    func budget(_ value: JSON, utf8: Int, ascii: Int) throws {
        let bytes = try value.data(); let expanded = String(decoding: bytes, as: UTF8.self).unicodeScalars.reduce(0) { $0 + ($1.value < 0x7f ? 1 : ($1.value <= 0xffff ? 6 : 12)) }
        guard bytes.count <= utf8, expanded <= ascii else { throw CoreError("preview_too_large", "Complete reminder review exceeds bounded wire size") }
    }
    func sign(_ envelope: JSON, domain: String, assessment: Bool = false) throws -> JSON {
        let tag = HMAC<SHA256>.authenticationCode(for: try authData(envelope, domain: domain), using: try state.signingKey())
        let preview: JSON = .object(["envelope": envelope, "authentication_tag": .string(Data(tag).base64EncodedString())])
        try budget(preview, utf8: assessment ? 327680 : 196608, ascii: assessment ? 921600 : 409600)
        return preview
    }
    func base(domain: String, action: String? = nil) throws -> [String: JSON] {
        let issued = now(); var value: [String: JSON] = ["version": .int(1), "domain": .string(domain), "nonce": .string(UUID().uuidString), "issued_at": .string(iso(issued)), "expires_at": .string(iso(issued.addingTimeInterval(600))), "installation_id": .string(try state.required("installation_id")), "credential_generation": .string(try state.required("credential_generation")), "key_id": .string(try state.required("key_id"))]
        if let action { value["action"] = .string(action) }; return value
    }
    func authenticate(_ arguments: JSON, keys: Set<String>, domain: String, assessment: Bool = false) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["preview"], required: ["preview"]), p = try Arguments(a.values["preview"]!, allowed: ["envelope", "authentication_tag"], required: ["envelope", "authentication_tag"])
        try budget(a.values["preview"]!, utf8: assessment ? 327680 : 196608, ascii: assessment ? 921600 : 409600)
        let envelope = p.values["envelope"]!; _ = try Arguments(envelope, allowed: keys, required: keys)
        guard envelope["version"] == .int(1), envelope["domain"] == .string(domain), envelope["installation_id"] == .string(try state.required("installation_id")), envelope["credential_generation"] == .string(try state.required("credential_generation")), envelope["key_id"] == .string(try state.required("key_id")), let tag = Data(base64Encoded: try p.string("authentication_tag")), tag.count == 32, HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: try authData(envelope, domain: domain), using: try state.signingKey()) else { throw CoreError("invalid_preview", "Reminder preview integrity or resource binding failed") }
        _ = try uuid(envelope["nonce"].string ?? ""); return envelope
    }
    func fresh(_ envelope: JSON) throws {
        guard let first = envelope["issued_at"].string, let last = envelope["expires_at"].string else { throw CoreError("invalid_preview", "Missing reminder preview times") }
        let issued = try parseDate(first), expiry = try parseDate(last), current = now()
        guard issued <= current.addingTimeInterval(30), expiry > current, expiry > issued, expiry.timeIntervalSince(issued) <= 600.001 else { throw CoreError("preview_expired", "Reminder preview expired; obtain a fresh exact review") }
    }
    func recovery(_ mode: String) -> JSON { .object(["mode": .string(mode), "limitations": Self.limitations]) }
    func changed(before: JSON, fields: ReminderFields) -> [String] {
        var keys = ["title", "notes", "priority", "start", "due"].filter { before["fields"][$0] != fields.observedJSON[$0] }
        if let alerts = fields.alerts, alarms(before["details"]) != .array(alerts.map(\.rawAlarm)) { keys.append("alerts") }
        return keys.sorted()
    }
    private func query(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["list_id", "status", "title_contains", "due_from", "due_to", "include_undated", "limit"], required: ["list_id"])
        let id = try uuid(a.string("list_id")); guard let pair = try lists().first(where: { $0.1["id"] == .string(id) }) else { throw CoreError("list_missing", "Reminder list is unavailable") }
        let status = a.values["status"]?.string ?? "incomplete", limit = a.values["limit"]?.integer ?? 50
        guard ["incomplete", "completed", "all"].contains(status), a.values["status"] == nil || a.values["status"]?.string != nil, (1...100).contains(limit), a.values["limit"] == nil || a.values["limit"]?.integer != nil else { throw CoreError("invalid_arguments", "Invalid reminder query status or limit") }
        let from = a.values["due_from"]?.string, to = a.values["due_to"]?.string, text = a.values["title_contains"]?.string
        for key in ["due_from", "due_to", "title_contains"] { guard a.values[key] == nil || a.values[key]?.string != nil else { throw CoreError("invalid_arguments", "Invalid reminder query text") } }
        if let from { try ReminderDate.validateLabel(from) }; if let to { try ReminderDate.validateLabel(to) }; if let from, let to { guard from < to else { throw CoreError("invalid_arguments", "Reminder due range must be increasing") } }
        guard text == nil || text!.unicodeScalars.count <= 1000, a.values["include_undated"] == nil || a.values["include_undated"]?.boolean != nil else { throw CoreError("invalid_arguments", "Invalid reminder query filter") }
        let undated = a.values["include_undated"]?.boolean ?? (from == nil && to == nil)
        let records = try backend.query(listID: pair.0.nativeID)
        var values: [JSON] = []
        for record in records {
            guard record.listNativeID == pair.0.nativeID else { throw CoreError("identity_ambiguous", "Provider returned a reminder outside the exact list") }
            if status == "incomplete" && record.completed || status == "completed" && !record.completed { continue }
            if let text, !record.fields.title.localizedCaseInsensitiveContains(text) { continue }
            if from != nil || to != nil || !undated {
                if record.unsupportedReasons.contains("unsupported_due_components") { throw CoreError("unsupported_reminder_date", "Cannot honestly filter an unsupported reminder due date") }
                if let due = record.fields.due { if let from, due.date < from { continue }; if let to, due.date >= to { continue } }
                else if !undated { continue }
            }
            values.append(try view(record))
        }
        values.sort { $0["id"].string! < $1["id"].string! }
        var page: [JSON] = [], truncated = values.count > limit
        for value in values.prefix(limit) {
            let candidate: JSON = .object(["reminders": .array(page + [value]), "truncated": .bool(truncated)])
            if try candidate.data().count > 393216 { truncated = true; break }; page.append(value)
        }
        return .object(["reminders": .array(page), "truncated": .bool(truncated)])
    }
    private func preflight(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["action", "scope", "list_id", "reminder_id", "fields"], required: ["action", "scope"]), action = try a.string("action")
        guard ["create", "modify", "complete", "reopen", "delete"].contains(action), arguments["scope"] == .string("this") else { throw CoreError("unsupported_scope", "Address one nonrecurring reminder") }
        let list: JSON, before: JSON, after: JSON, policy: String, mask: [String]
        if action == "create" {
            guard a.values["reminder_id"] == nil, let patch = a.values["fields"], let pair = try lists().first(where: { $0.1["id"] == .string(try a.string("list_id")) }), pair.0.writable else { throw CoreError("read_only", "Create requires an exact writable reminder list and fields") }
            let fields = try ReminderFields.merged(patch, with: nil)
            list = pair.1; before = .null; after = .object(["fields": fields.json, "completed": .bool(false)]); policy = "clear"; mask = Self.fields.sorted()
        } else {
            guard a.values["list_id"] == nil else { throw CoreError("invalid_arguments", "Reminder list moves are unsupported") }
            let record = try reminder(a.string("reminder_id")); try eligible(record); before = try view(record)
            guard let pair = try lists().first(where: { $0.0.nativeID == record.listNativeID }), pair.0.writable else { throw CoreError("read_only", "Reminder list is not writable") }; list = pair.1
            if action == "modify" {
                guard let patch = a.values["fields"] else { throw CoreError("invalid_fields", "Reminder modification needs fields") }
                var fields = try ReminderFields.merged(patch, with: record.fields)
                if fields.alerts != nil { try ReminderAlert.validateRaw(alarms(record.details)) }
                mask = changed(before: before, fields: fields); if !mask.contains("alerts") { fields.alerts = nil }; guard !mask.isEmpty else { throw CoreError("no_change", "No reminder fields changed") }
                after = .object(["fields": fields.json, "completed": .bool(record.completed)]); policy = "preserve"
            } else {
                guard a.values["fields"] == nil else { throw CoreError("invalid_arguments", "Complete, reopen and delete do not accept fields") }
                if action == "delete" { try restorable(record); after = .null; mask = []; policy = "none" }
                else {
                    let completed = action == "complete"; guard completed != record.completed else { throw CoreError("no_change", "Reminder completion state is unchanged") }
                    after = .object(["fields": record.fields.observedJSON, "completed": .bool(completed)]); mask = ["completed"]; policy = completed ? "set_on_commit" : "clear"
                }
            }
        }
        var envelope = try base(domain: "reminders", action: action)
        envelope.merge(["scope": .string("this"), "list": list, "before": before, "after": after, "changed_fields": .array(mask.map(JSON.string)), "completion_date_policy": .string(policy), "recovery": recovery(action == "create" ? "delete_created" : (action == "delete" ? "limited_copy" : "inverse_fields")), "rollback": .null]) { _, new in new }
        let value = JSON.object(envelope); try state.assertNoConflict(value)
        return .object(["preview": try sign(value, domain: "reminders"), "safety": try state.safety(action: action, now: now())])
    }
}
