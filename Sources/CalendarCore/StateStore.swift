import Foundation
import CryptoKit
import CSQLite
import Darwin

public final class StateStore {
    var database: OpaquePointer?
    private var lockFD: Int32 = -1
    var localNativeReview = false
    public let directory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        let fm = FileManager.default
        try fm.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try fm.attributesOfItem(atPath: self.directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory, (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CoreError("unsafe_state", "State directory must be owned by the current user and not a symlink") }
        guard chmod(self.directory.path, 0o700) == 0 else { throw CoreError("unsafe_state", "Cannot protect state directory") }
        let lockPath = self.directory.appendingPathComponent("broker.lock").path
        lockFD = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { if lockFD >= 0 { close(lockFD) }; lockFD = -1; throw CoreError("broker_running", "Another broker owns this state directory") }
        let path = self.directory.appendingPathComponent("state.sqlite3").path
        if fm.fileExists(atPath: path) {
            let attr = try fm.attributesOfItem(atPath: path)
            guard attr[.type] as? FileAttributeType == .typeRegular, (attr[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CoreError("unsafe_state", "Unsafe database file") }
            guard chmod(path, 0o600) == 0 else { throw CoreError("unsafe_state", "Cannot protect database") }
        }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw CoreError("audit_unavailable", "Cannot open native state") }
        guard chmod(path, 0o600) == 0 else { throw CoreError("unsafe_state", "Cannot protect database") }
        sqlite3_busy_timeout(database, 5000)
        try execute("PRAGMA journal_mode=DELETE")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA secure_delete=ON")
        try execute("PRAGMA fullfsync=ON")
        try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS identities (id TEXT PRIMARY KEY, kind TEXT NOT NULL, native_id TEXT NOT NULL, calendar_id TEXT NOT NULL, occurrence TEXT NOT NULL, known_start TEXT NOT NULL, UNIQUE(kind,native_id,calendar_id,occurrence))")
        try execute("CREATE TABLE IF NOT EXISTS executions (nonce TEXT PRIMARY KEY, payload TEXT NOT NULL, state TEXT NOT NULL, result TEXT NOT NULL, created TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS write_safety_claims (nonce TEXT PRIMARY KEY, action TEXT NOT NULL CHECK(action IN ('modify','delete')), charged_at TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS write_safety_time ON write_safety_claims(charged_at)")
        try execute("CREATE TRIGGER IF NOT EXISTS write_safety_no_update BEFORE UPDATE ON write_safety_claims BEGIN SELECT RAISE(ABORT,'immutable quota claim'); END")
        try execute("CREATE TRIGGER IF NOT EXISTS write_safety_no_delete BEFORE DELETE ON write_safety_claims BEGIN SELECT RAISE(ABORT,'immutable quota claim'); END")
        try execute("CREATE TABLE IF NOT EXISTS audit (sequence INTEGER PRIMARY KEY, body TEXT NOT NULL, previous_hash TEXT NOT NULL, hash TEXT NOT NULL)")
        try execute("CREATE TRIGGER IF NOT EXISTS audit_no_update BEFORE UPDATE ON audit BEGIN SELECT RAISE(ABORT,'append only'); END")
        try execute("CREATE TRIGGER IF NOT EXISTS audit_no_delete BEFORE DELETE ON audit BEGIN SELECT RAISE(ABORT,'append only'); END")
        try execute("CREATE TRIGGER IF NOT EXISTS payload_immutable BEFORE UPDATE OF nonce,payload,created ON executions BEGIN SELECT RAISE(ABORT,'immutable payload'); END")
        if try metadata("installation_id") == nil {
            try transaction {
                try setMetadata("installation_id", UUID().uuidString)
                try rotateCredentialsInsideTransaction()
            }
        }
        try installCommitObservationStorage()
        try execute("CREATE INDEX IF NOT EXISTS executions_state ON executions(state)")
        try migrateRecoveryStorage()
        try verifyAudit()
        try transaction {
            // Earlier native executions are part of the same installation budget.
            // Outcomes never refund quota, including a not_applied attestation.
            for row in try rows("SELECT e.nonce,e.payload,e.created FROM executions e LEFT JOIN write_safety_claims q ON q.nonce=e.nonce WHERE q.nonce IS NULL") {
                let payload = try JSON.parse(Data(row[1].utf8))
                guard let action = payload["action"].string, ["create", "modify", "delete"].contains(action) else { throw CoreError("state_corrupt", "Execution journal has an invalid action") }
                let created = try parseDate(row[2])
                if action != "create" {
                    try execute("INSERT INTO write_safety_claims(nonce,action,charged_at) VALUES(?,?,?)", [row[0], action, iso(created)])
                }
            }
            if try metadata("write_safety_policy") == nil {
                _ = try adoptWriteSafetyPolicy(loaded: (WriteSafetyPolicy.defaults, false))
            }
            _ = try storedWriteSafetyPolicy()
        }
        try expireRecoveryDetails(now: Date())
        // Intent survives any process termination; do not assume EventKit was untouched.
        let stranded = try rows("SELECT nonce FROM executions WHERE state='intent_recorded'")
        for row in stranded {
            try finish(nonce: row[0], state: "unknown", result: .object(["state": .string("unknown"), "nonce": .string(row[0]), "message": .string("Broker stopped after durable intent; inspect before reconciliation")]), event: "recovered_unknown")
        }
    }
    deinit { if let database { sqlite3_close(database) }; if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw CoreError("audit_unavailable", "Native state preparation failed") }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient) == SQLITE_OK else { sqlite3_finalize(stmt); throw CoreError("audit_unavailable", "Native state binding failed") }
        }; return stmt
    }
    func execute(_ sql: String, _ values: [String] = []) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw CoreError("audit_unavailable", "Native durable state operation failed") }
    }
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        var result: [[String]] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw CoreError("audit_unavailable", "Native state read failed") }
            result.append((0..<sqlite3_column_count(stmt)).map { i in sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" })
        }
    }
    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try work(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func metadata(_ key: String) throws -> String? { try rows("SELECT value FROM metadata WHERE key=?", [key]).first?.first }
    private func setMetadata(_ key: String, _ value: String) throws { try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES(?,?)", [key, value]) }
    private func rotateCredentialsInsideTransaction() throws {
        try setMetadata("credential_generation", UUID().uuidString)
        try setMetadata("key_id", UUID().uuidString)
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        try setMetadata("signing_key", key)
    }
    public func rotateCredentials() throws {
        try transaction { try rotateCredentialsInsideTransaction(); _ = try appendInsideTransaction(event: "credentials_rotated", nonce: nil, payload: .object([:])) }
    }
    public func configure(backendMode: String, credentialBinding: String) throws {
        guard ["eventkit", "synthetic"].contains(backendMode), credentialBinding.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw CoreError("invalid_configuration", "Expected backend mode and SHA256 gateway credential binding") }
        try transaction {
            if let existing = try metadata("backend_mode"), existing != backendMode { throw CoreError("backend_mismatch", "State directory belongs to another backend mode") }
            try setMetadata("backend_mode", backendMode)
            if try metadata("credential_binding") != credentialBinding {
                try rotateCredentialsInsideTransaction()
                try setMetadata("credential_binding", credentialBinding)
                _ = try appendInsideTransaction(event: "credential_binding_rotated", nonce: nil, payload: .object(["backend_mode": .string(backendMode)]))
            }
        }
    }
    public func identity(kind: String, nativeID: String, calendarID: String = "", occurrence: String? = nil, knownStart: String = "") throws -> String {
        if let row = try rows("SELECT id,known_start FROM identities WHERE kind=? AND native_id=? AND calendar_id=? AND occurrence=?", [kind, nativeID, calendarID, occurrence ?? ""]).first {
            if row[1] != knownStart { try execute("UPDATE identities SET known_start=? WHERE id=?", [knownStart, row[0]]) }; return row[0]
        }
        let id = UUID().uuidString
        try execute("INSERT INTO identities(id,kind,native_id,calendar_id,occurrence,known_start) VALUES(?,?,?,?,?,?)", [id, kind, nativeID, calendarID, occurrence ?? "", knownStart]); return id
    }
    public func resolve(_ id: String, kind: String) throws -> (nativeID: String, calendarID: String, occurrence: String?, knownStart: String) {
        guard let row = try rows("SELECT native_id,calendar_id,occurrence,known_start FROM identities WHERE id=? AND kind=?", [id, kind]).first else { throw CoreError("identity_missing", "Unknown integration identity; query again") }
        return (row[0], row[1], row[2].isEmpty ? nil : row[2], row[3])
    }
    /// Only used with the direct, verified integration save result. Never heuristic relinking.
    public func rebindEvent(id: String, to event: EventRecord) throws {
        try transaction {
            _ = try resolve(id, kind: "event")
            let conflicts = try rows("SELECT id FROM identities WHERE kind='event' AND native_id=? AND calendar_id=? AND occurrence=? AND id<>?", [event.nativeID, event.calendarNativeID, event.occurrence ?? "", id])
            guard conflicts.isEmpty else { throw CoreError("identity_ambiguous", "Verified saved identity already maps to another event") }
            try execute("UPDATE identities SET native_id=?,calendar_id=?,occurrence=?,known_start=? WHERE id=? AND kind='event'", [event.nativeID, event.calendarNativeID, event.occurrence ?? "", event.fields.start, id])
        }
    }
    public func execution(_ nonce: String) throws -> (payload: JSON, state: String, result: JSON)? {
        guard let row = try rows("SELECT payload,state,result FROM executions WHERE nonce=?", [nonce]).first else { return nil }
        let marker = try JSON.parse(Data(row[0].utf8))
        return (try secret(nonce: nonce, column: "payload_cipher") ?? marker, row[1], try secret(nonce: nonce, column: "result_cipher") ?? JSON.parse(Data(row[2].utf8)))
    }
    public func payloadMatches(nonce: String, payload: JSON) throws -> Bool {
        guard let row = try rows("SELECT payload FROM executions WHERE nonce=?", [nonce]).first else { return false }
        return try JSON.parse(Data(row[0].utf8))["payload_digest"] == .string(digest(payload.data()))
    }
    public func hasUnresolved() throws -> Bool { !(try rows("SELECT nonce FROM executions WHERE state IN ('intent_recorded','unknown') LIMIT 1")).isEmpty }
    private func currentWriteSafetyPolicy() throws -> (policy: WriteSafetyPolicy, file: Bool) {
        if let policy = try WriteSafetyPolicy.read(directory: directory) { return (policy, true) }
        guard try metadata("write_safety_file_adopted") != "true" else { throw CoreError("write_safety_configuration", "Previously adopted local write-safety.json is missing; restore a protected valid policy before writing") }
        return (WriteSafetyPolicy.defaults, false)
    }
    private func storedWriteSafetyPolicy() throws -> WriteSafetyPolicy {
        guard let canonical = try metadata("write_safety_policy"),
              try metadata("write_safety_hash") == digest(Data(canonical.utf8)),
              let revision = try metadata("write_safety_revision").flatMap(Int.init), revision > 0,
              ["true", "false"].contains(try metadata("write_safety_file_adopted") ?? "") else {
            throw CoreError("state_corrupt", "Invalid durable write safety configuration")
        }
        return try WriteSafetyPolicy(json: JSON.parse(Data(canonical.utf8)))
    }
    /// Only called within a transaction. Configuration adoption does not erase usage.
    private func adoptWriteSafetyPolicy(loaded supplied: (policy: WriteSafetyPolicy, file: Bool)? = nil) throws -> WriteSafetyPolicy {
        let loaded = try supplied ?? currentWriteSafetyPolicy()
        let canonical = try loaded.policy.json.text(), previous = try metadata("write_safety_policy")
        let adopted = try metadata("write_safety_file_adopted") == "true"
        if previous != canonical || (loaded.file && !adopted) {
            let revision = (try metadata("write_safety_revision").flatMap(Int.init) ?? 0) + 1
            try setMetadata("write_safety_policy", canonical)
            try setMetadata("write_safety_hash", digest(Data(canonical.utf8)))
            try setMetadata("write_safety_revision", String(revision))
            try setMetadata("write_safety_file_adopted", loaded.file || adopted ? "true" : "false")
            _ = try appendInsideTransaction(event: "write_safety_policy_changed", nonce: nil, payload: .object([
                "previous": try previous.map { try JSON.parse(Data($0.utf8)) } ?? .null,
                "policy": loaded.policy.json, "revision": .int(revision),
                "policy_hash": .string(digest(Data(canonical.utf8))), "source": .string(loaded.file ? "local_file" : "defaults")
            ]))
        }
        return loaded.policy
    }
    private func writeSafetySnapshot(action: String, now: Date, policy: WriteSafetyPolicy) throws -> (json: JSON, rejection: CoreError?) {
        let latest = try rows("SELECT charged_at FROM write_safety_claims ORDER BY charged_at DESC LIMIT 1").first?.first
        let effective = try latest.map { max(now, try parseDate($0)) } ?? now
        let claims = try rows("SELECT action,charged_at FROM write_safety_claims WHERE charged_at>? ORDER BY charged_at", [iso(effective.addingTimeInterval(-86_400))])
        let windows: [(String, String?, TimeInterval, Int)] = [
            ("delete_hour", "delete", 3600, policy.deleteHour), ("delete_day", "delete", 86_400, policy.deleteDay),
            ("destructive_hour", nil, 3600, policy.destructiveHour), ("destructive_day", nil, 86_400, policy.destructiveDay)
        ]
        var usage: [String: JSON] = [:], blocked: [String] = [], retry: Date?
        for (name, filter, seconds, limit) in windows {
            let times = try claims.filter { filter == nil || $0[0] == filter }.map { try parseDate($0[1]) }.filter { $0 > effective.addingTimeInterval(-seconds) }
            let applicable = action == "delete" || (action == "modify" && filter == nil)
            let next = times.count >= limit ? times[times.count - limit].addingTimeInterval(seconds) : nil
            usage[name] = .object(["limit": .int(limit), "used": .int(times.count), "remaining": .int(max(0, limit - times.count)), "window_seconds": .int(Int(seconds)), "next_available_at": next.map { .string(iso($0)) } ?? .null])
            if applicable && times.count >= limit { blocked.append(name); if let next { retry = max(retry ?? next, next) } }
        }
        let status: JSON = .object([
            "policy": policy.json, "policy_hash": .string(digest(try policy.json.data())),
            "action": .string(action), "applies": .bool(action != "create"), "allowed_now": .bool(blocked.isEmpty),
            "effective_at": .string(iso(effective)), "clock_rollback": .bool(effective > now), "usage": .object(usage),
            "retry_at": retry.map { .string(iso($0)) } ?? .null, "advisory": .bool(true),
            "message": .string("Installation-wide durable intent budgets across calls, chats and restarts. Modify and delete share the destructive limits. Preflight reserves no capacity; commit checks current local policy again.")
        ])
        let rejection = retry.map { CoreError("write_safety_limit", "Local write safety limit reached (\(blocked.joined(separator: ", "))); retry no earlier than \(iso($0)). Wait or ask the local operator to adjust protected write-safety.json; a new chat or preview does not reset usage") }
        return (status, rejection)
    }
    public func writeSafety(action: String, now: Date) throws -> JSON {
        try writeSafetySnapshot(action: action, now: now, policy: action == "create" ? storedWriteSafetyPolicy() : currentWriteSafetyPolicy().policy).json
    }
    public func claim(nonce: String, payload: JSON, now: Date) throws -> Int {
        let result: (sequence: Int?, rejection: CoreError?) = try transaction {
            guard try execution(nonce) == nil else { throw CoreError("nonce_replayed", "Nonce already claimed") }
            guard try !hasUnresolved() else { throw CoreError("unresolved_write", "An earlier write outcome is unresolved; inspect status and reconcile locally") }
            guard let action = payload["action"].string, ["create", "modify", "delete"].contains(action) else { throw CoreError("invalid_preview", "Invalid execution action") }
            if action != "create" {
                let policy = try adoptWriteSafetyPolicy()
                let snapshot = try writeSafetySnapshot(action: action, now: now, policy: policy)
                let accounting: JSON = .object(["safety": snapshot.json, "policy_revision": .string(try metadata("write_safety_revision") ?? "")])
                // Keep accepted configuration and its audit even when quota denies a new intent.
                if let rejection = snapshot.rejection {
                    return (nil, rejection)
                }
                try execute("INSERT INTO write_safety_claims(nonce,action,charged_at) VALUES(?,?,?)", [nonce, action, snapshot.json["effective_at"].string!])
                _ = try appendInsideTransaction(event: "write_safety_charged", nonce: nonce, payload: accounting)
            }
            let result: JSON = .object(["nonce": .string(nonce), "state": .string("intent_recorded")])
            try storeIntent(nonce: nonce, payload: payload, result: result, now: now)
            return (try appendInsideTransaction(event: "write_intent", nonce: nonce, payload: payload), nil)
        }
        if let rejection = result.rejection { throw rejection }; return result.sequence!
    }
    public func finish(nonce: String, state: String, result: JSON, event: String) throws {
        try transaction {
            guard try execution(nonce) != nil else { throw CoreError("audit_unavailable", "Execution journal missing") }
            try storeResult(nonce: nonce, state: state, result: result)
            _ = try appendInsideTransaction(event: event, nonce: nonce, payload: result)
        }
    }
    public func reconcile(nonce: String, outcome: String, evidence: String) throws -> JSON {
        guard let parsed = UUID(uuidString: nonce) else { throw CoreError("invalid_reconciliation", "Invalid nonce") }; let nonce = parsed.uuidString
        guard ["applied", "not_applied"].contains(outcome), !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, evidence.count <= 10_000,
              let previous = try execution(nonce), previous.state == "unknown" else { throw CoreError("invalid_reconciliation", "Only unknown executions can be reconciled with explicit evidence") }
        let result: JSON = .object(["nonce": .string(nonce), "state": .string("reconciled"), "outcome": .string(outcome), "resolution_source": .string("local_operator_attestation"), "evidence": .string(evidence), "previous_result": previous.result])
        try finish(nonce: nonce, state: "reconciled", result: result, event: "operator_reconciliation"); return result
    }
    @discardableResult public func append(event: String, nonce: String?, payload: JSON) throws -> Int {
        try transaction { try appendInsideTransaction(event: event, nonce: nonce, payload: payload) }
    }
    func appendInsideTransaction(event: String, nonce: String?, payload: JSON) throws -> Int {
        let last = try rows("SELECT sequence,hash FROM audit ORDER BY sequence DESC LIMIT 1").first
        let sequence = (last.flatMap { Int($0[0]) } ?? 0) + 1
        let previous = last?[1] ?? String(repeating: "0", count: 64)
        let origin = ["recovery_migration_checkpoint", "details_expired", "commit_observation_checkpoint"].contains(event) ? "native_maintenance" : (event == "operator_reconciliation" ? "local_operator_attestation" : (event.contains("credential") || event == "write_safety_policy_changed" ? "local_configuration" : (event == "recovered_unknown" ? "native_recovery" : "chatgpt_host_policy")))
        let localWriteEvent = localNativeReview && ["write_intent", "write_applied", "write_unknown", "commit_replayed", "commit_rejected", "write_safety_charged", "write_safety_rejected"].contains(event)
        let body: JSON = .object(["version": .int(2), "record_sequence": .int(sequence), "event_id": .string(UUID().uuidString), "timestamp": .string(iso(Date())), "event": .string(event), "nonce": .optional(nonce), "approval_source": .string(localWriteEvent ? "local_native_ui" : origin), "approval_evidence": .string(localWriteEvent ? "native_control_activated" : "not_provided"), "payload": safeAuditPayload(event: event, nonce: nonce, payload: payload)])
        let hash = digest(Data(previous.utf8) + (try body.data()))
        try execute("INSERT INTO audit(sequence,body,previous_hash,hash) VALUES(?,?,?,?)", [String(sequence), try body.text(), previous, hash]); return sequence
    }
    func auditSequence(_ body: JSON) throws -> Int? { body["version"] == .int(2) ? body["record_sequence"].integer : body["sequence"].integer }
    public func verifyAudit() throws {
        var previous = String(repeating: "0", count: 64); var sequence = 0
        for row in try rows("SELECT sequence,body,previous_hash,hash FROM audit ORDER BY sequence") {
            sequence += 1
            guard row[0] == String(sequence), row[2] == previous,
                  digest(Data(previous.utf8) + Data(row[1].utf8)) == row[3],
                  try auditSequence(JSON.parse(Data(row[1].utf8))) == sequence else { throw CoreError("audit_corrupt", "Audit chain verification failed; writes disabled") }
            previous = row[3]
        }
        if try metadata("recovery_storage_version") == "2" { try verifyLegacyManifest() }
    }
    public func auditRecords() throws -> [JSON] { try rows("SELECT body FROM audit ORDER BY sequence").map { try JSON.parse(Data($0[0].utf8)) } }
}
