import Foundation

/// Rejections and replays are durable operational counts, not fresh approvals or
/// immutable per-attempt evidence. Hourly checkpoints bind cumulative snapshots
/// into the existing audit chain; execution, nonce and quota records stay exact.
extension StateStore {
    static let observationInterval: TimeInterval = 3600
    private static let observationOperations = ["commit_create", "commit_modify", "commit_delete", "commit_rollback", "other_commit"]
    private static let observationReasons = ["invalid_request", "invalid_preview", "stale_state", "preview_expired", "unresolved_write", "write_safety_limit", "configuration", "unsupported_change", "audit_unavailable", "native_error", "other", "recorded_outcome"]

    func installCommitObservationStorage() throws {
        try execute("CREATE TABLE IF NOT EXISTS commit_observations(kind TEXT NOT NULL CHECK(kind IN ('rejected','replayed')),operation TEXT NOT NULL CHECK(operation IN ('commit_create','commit_modify','commit_delete','commit_rollback','other_commit')),reason TEXT NOT NULL CHECK(reason IN ('invalid_request','invalid_preview','stale_state','preview_expired','unresolved_write','write_safety_limit','configuration','unsupported_change','audit_unavailable','native_error','other','recorded_outcome')),origin TEXT NOT NULL CHECK(origin IN ('chatgpt_host_policy','local_native_ui')),count INTEGER NOT NULL CHECK(typeof(count)='integer' AND count>0),checkpoint_count INTEGER NOT NULL CHECK(typeof(checkpoint_count)='integer' AND checkpoint_count>=0 AND checkpoint_count<=count),first_at TEXT NOT NULL,last_at TEXT NOT NULL,PRIMARY KEY(kind,operation,reason,origin))")
        try execute("CREATE TABLE IF NOT EXISTS commit_observation_clock(id INTEGER PRIMARY KEY CHECK(id=1),highwater TEXT NOT NULL,last_checkpoint TEXT NOT NULL)")
    }
    private func observationReason(_ code: String) -> String {
        switch code {
        case "invalid_arguments", "unknown_operation", "request_too_large": return "invalid_request"
        case "invalid_preview", "nonce_conflict", "nonce_replayed": return "invalid_preview"
        case "stale_event", "stale_calendar", "stale_rollback", "event_missing", "calendar_missing", "identity_missing", "identity_ambiguous": return "stale_state"
        case "preview_expired": return "preview_expired"
        case "unresolved_write": return "unresolved_write"
        case "write_safety_limit": return "write_safety_limit"
        case "write_safety_configuration", "recovery_configuration", "invalid_configuration": return "configuration"
        case "unsupported_restore", "unsupported_scope", "unsupported_change", "calendar_read_only", "read_only", "ineligible_event": return "unsupported_change"
        case "audit_unavailable", "audit_corrupt", "state_corrupt": return "audit_unavailable"
        case "native_error": return "native_error"
        default: return "other"
        }
    }
    func recordCommitObservation(replayed: Bool, operation: String, code: String? = nil, now: Date) throws {
        try transaction {
            let kind = replayed ? "replayed" : "rejected"
            let operation = Self.observationOperations.contains(operation) ? operation : "other_commit"
            let reason = replayed ? "recorded_outcome" : observationReason(code ?? "native_error")
            let origin = localNativeReview ? "local_native_ui" : "chatgpt_host_policy"
            let effective = try observationTime(now: now, create: true)!
            let values = [kind, operation, reason, origin]
            if let row = try rows("SELECT count,checkpoint_count,first_at,last_at FROM commit_observations WHERE kind=? AND operation=? AND reason=? AND origin=?", values).first {
                guard let count = Int(row[0]), count > 0, count < Int.max,
                      let checkpoint = Int(row[1]), checkpoint >= 0, checkpoint <= count,
                      try parseDate(row[2]) <= parseDate(row[3]), try parseDate(row[3]) <= effective else {
                    throw CoreError("audit_unavailable", "Commit observation counter is corrupt or exhausted")
                }
                try execute("UPDATE commit_observations SET count=?,last_at=? WHERE kind=? AND operation=? AND reason=? AND origin=?", [String(count + 1), iso(effective)] + values)
            } else {
                try execute("INSERT INTO commit_observations VALUES(?,?,?,?,1,0,?,?)", values + [iso(effective), iso(effective)])
            }
            try checkpointCommitObservationsInsideTransaction(now: effective)
        }
    }
    private func observationTime(now: Date, create: Bool) throws -> Date? {
        if let row = try rows("SELECT highwater,last_checkpoint FROM commit_observation_clock WHERE id=1").first {
            let highwater = try parseDate(row[0]), checkpoint = try parseDate(row[1])
            guard highwater >= checkpoint else { throw CoreError("audit_unavailable", "Commit observation clock is corrupt") }
            let effective = max(now, highwater)
            try execute("UPDATE commit_observation_clock SET highwater=? WHERE id=1", [iso(effective)])
            return effective
        }
        guard create else {
            guard try rows("SELECT kind FROM commit_observations LIMIT 1").isEmpty else { throw CoreError("audit_unavailable", "Commit observation clock is missing") }
            return nil
        }
        guard try rows("SELECT kind FROM commit_observations LIMIT 1").isEmpty else { throw CoreError("audit_unavailable", "Commit observation clock is missing") }
        try execute("INSERT INTO commit_observation_clock VALUES(1,?,?)", [iso(now), iso(now)])
        return now
    }
    private func observationRows() throws -> [JSON] {
        try rows("SELECT kind,operation,reason,origin,count,checkpoint_count,first_at,last_at FROM commit_observations ORDER BY kind,operation,reason,origin").map { row in
            guard ["rejected", "replayed"].contains(row[0]), Self.observationOperations.contains(row[1]), Self.observationReasons.contains(row[2]), ["chatgpt_host_policy", "local_native_ui"].contains(row[3]),
                  let count = Int(row[4]), count > 0, let checkpoint = Int(row[5]), checkpoint >= 0, checkpoint <= count,
                  try parseDate(row[6]) <= parseDate(row[7]) else { throw CoreError("audit_unavailable", "Invalid commit observation accounting") }
            return .object(["kind": .string(row[0]), "operation": .string(row[1]), "reason": .string(row[2]), "origin": .string(row[3]), "count": .int(count), "checkpoint_count": .int(checkpoint), "pending_count": .int(count - checkpoint), "first_at": .string(row[6]), "last_at": .string(row[7])])
        }
    }
    private func checkpointCommitObservationsInsideTransaction(now: Date) throws {
        guard let row = try rows("SELECT last_checkpoint FROM commit_observation_clock WHERE id=1").first else { return }
        guard now.timeIntervalSince(try parseDate(row[0])) >= Self.observationInterval else { return }
        let observations = try observationRows()
        guard observations.contains(where: { ($0["pending_count"].integer ?? 0) > 0 }) else { return }
        _ = try appendInsideTransaction(event: "commit_observation_checkpoint", nonce: nil, payload: .object(["accounting": .string("cumulative_operational_counts"), "checkpoint_at": .string(iso(now)), "previous_checkpoint_at": .string(row[0]), "interval_seconds": .int(Int(Self.observationInterval)), "observations": .array(observations)]))
        try execute("UPDATE commit_observations SET checkpoint_count=count")
        try execute("UPDATE commit_observation_clock SET last_checkpoint=? WHERE id=1", [iso(now)])
    }
    public func maintainCommitObservations(now: Date) throws {
        try transaction {
            if let effective = try observationTime(now: now, create: false) { try checkpointCommitObservationsInsideTransaction(now: effective) }
        }
    }
    public func commitObservationStatus() throws -> JSON {
        let clock = try rows("SELECT highwater,last_checkpoint FROM commit_observation_clock WHERE id=1").first
        if let clock { guard try parseDate(clock[0]) >= parseDate(clock[1]) else { throw CoreError("audit_unavailable", "Commit observation clock is corrupt") } }
        let observations = try observationRows()
        guard clock != nil || observations.isEmpty else { throw CoreError("audit_unavailable", "Commit observation clock is missing") }
        return .object(["accounting": .string("cumulative_operational_counts"), "per_attempt_audit": .bool(false), "checkpoint_interval_seconds": .int(Int(Self.observationInterval)), "highwater_at": .optional(clock?.first), "last_checkpoint_at": .optional(clock?.last), "observations": .array(observations)])
    }
}
