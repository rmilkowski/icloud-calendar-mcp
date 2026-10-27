// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit
import CSQLite
import Darwin

public struct ReminderExecution {
    public let nonce: String, state: String, created: String
    public let payload: JSON, result: JSON, marker: JSON
    public let detailsAvailable: Bool
}

/// A separate resource database. No Calendar state, identities, quota or signing keys are opened.
public final class ReminderStateStore {
    public let directory: URL
    private var database: OpaquePointer?
    var provenNonExecution: [String: String] = [:]
    private var lockFD: Int32 = -1
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(directory: URL, backendMode: String, credentialBinding: String) throws {
        guard ["synthetic", "eventkit"].contains(backendMode), credentialBinding.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CoreError("invalid_configuration", "Invalid Reminders backend binding") }
        let supplied = directory.standardizedFileURL
        let fm = FileManager.default
        try fm.createDirectory(at: supplied, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(supplied.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw CoreError("unsafe_state", "Reminders state must be an owned private directory") }
        guard let resolved = realpath(supplied.path, nil) else { throw CoreError("unsafe_state", "Cannot resolve protected Reminders directory") }
        self.directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true); free(resolved)
        var initialized = false
        defer {
            if !initialized {
                if let database { sqlite3_close(database); self.database = nil }
                if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
            }
        }
        lockFD = open(self.directory.appendingPathComponent("reminders.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0, fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw CoreError("broker_running", "Cannot exclusively own protected Reminders state") }
        let path = self.directory.appendingPathComponent("reminders.sqlite3").path
        let exists = lstat(path, &info) == 0
        if exists { guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600, info.st_size > 0 else { throw CoreError("unsafe_state", "Unsafe Reminders database") } }
        else {
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CoreError("unsafe_state", "Cannot create private Reminders database") }; close(fd)
        }
        let openCode = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard openCode == SQLITE_OK else { throw CoreError("audit_unavailable", "Cannot open Reminders database") }
        sqlite3_busy_timeout(database, 5000)
        if exists {
            guard try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='metadata'").count == 1,
                  try metadata("resource") == "reminders", try metadata("domain") == "reminders", try metadata("recovery_storage_version") == "reminders-1" else { throw CoreError("state_version", "State does not belong to this Reminders writer") }
        }
        try execute("PRAGMA journal_mode=DELETE"); try execute("PRAGMA synchronous=FULL"); try execute("PRAGMA fullfsync=ON"); try execute("PRAGMA secure_delete=ON")
        if !exists { try install() }
        guard try metadata("resource") == "reminders", try metadata("domain") == "reminders", try metadata("recovery_storage_version") == "reminders-1" else { throw CoreError("state_version", "Unsupported Reminders state") }
        try verifyAudit()
        try transaction {
            guard try metadata("backend_mode") == nil || metadata("backend_mode") == backendMode else { throw CoreError("backend_mismatch", "Reminders state belongs to another backend") }
            try setMetadata("backend_mode", backendMode)
            if try metadata("credential_binding") != credentialBinding {
                try setMetadata("credential_binding", credentialBinding)
                try setMetadata("credential_generation", UUID().uuidString); try setMetadata("key_id", UUID().uuidString)
                try setMetadata("signing_key", SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() })
                _ = try appendInside("credentials_rotated", nonce: nil, payload: .object([:]), origin: "local_configuration")
            }
        }
        for row in try rows("SELECT nonce FROM executions WHERE state='intent_recorded'") {
            try finish(nonce: row[0], state: "unknown", result: .object(["nonce": .string(row[0]), "state": .string("unknown"), "action": try execution(row[0])!.marker["action"], "message": .string("Reminders broker stopped after durable intent; inspect the original change without retrying")]), event: "recovered_unknown", origin: "native_recovery")
        }
        try expire(now: Date())
        initialized = true
    }
    deinit { if let database { sqlite3_close(database) }; if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
    func execute(_ sql: String, _ values: [String] = []) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement); guard code == SQLITE_DONE || code == SQLITE_ROW else { throw CoreError("audit_unavailable", "Reminders durable operation failed") }
    }
    private func prepare(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CoreError("audit_unavailable", "Reminders state preparation failed") }
        for (index, value) in values.enumerated() { guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { sqlite3_finalize(statement); throw CoreError("audit_unavailable", "Reminders state binding failed") } }
        return statement
    }
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }; var result: [[String]] = []
        while true { let code = sqlite3_step(statement); if code == SQLITE_DONE { return result }; guard code == SQLITE_ROW else { throw CoreError("state_corrupt", "Reminders state read failed") }; result.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" }) }
    }
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try operation(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func metadata(_ key: String) throws -> String? { try rows("SELECT value FROM metadata WHERE key=?", [key]).first?.first }
    func setMetadata(_ key: String, _ value: String) throws { try execute("INSERT OR REPLACE INTO metadata VALUES(?,?)", [key, value]) }
    func required(_ key: String) throws -> String { guard let value = try metadata(key) else { throw CoreError("state_corrupt", "Missing Reminders identity") }; return value }
    func signingKey() throws -> SymmetricKey { guard let bytes = Data(base64Encoded: try required("signing_key")), bytes.count == 32 else { throw CoreError("state_corrupt", "Invalid Reminders signing key") }; return SymmetricKey(data: bytes) }
    private func install() throws {
        try transaction {
            for sql in [
                "CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
                "CREATE TABLE identities(id TEXT PRIMARY KEY,kind TEXT NOT NULL,native_id TEXT NOT NULL,list_native_id TEXT NOT NULL,UNIQUE(kind,native_id,list_native_id))",
                "CREATE TABLE executions(nonce TEXT PRIMARY KEY,marker TEXT NOT NULL,state TEXT NOT NULL,result TEXT NOT NULL,created TEXT NOT NULL,source_nonce TEXT)",
                "CREATE TABLE details(nonce TEXT PRIMARY KEY,payload_cipher TEXT NOT NULL,result_cipher TEXT NOT NULL,captured TEXT NOT NULL,expires TEXT NOT NULL,expired INTEGER NOT NULL DEFAULT 0)",
                "CREATE TABLE execution_keys(nonce TEXT PRIMARY KEY,key TEXT NOT NULL)",
                "CREATE TABLE quota(nonce TEXT PRIMARY KEY,action TEXT NOT NULL,charged_at TEXT NOT NULL)",
                "CREATE TABLE audit(sequence INTEGER PRIMARY KEY,body TEXT NOT NULL,previous_hash TEXT NOT NULL,hash TEXT NOT NULL)",
                "CREATE TABLE observations(bucket TEXT PRIMARY KEY,count INTEGER NOT NULL,checkpointed INTEGER NOT NULL)",
                "CREATE TABLE assessments(nonce TEXT PRIMARY KEY,source_nonce TEXT NOT NULL UNIQUE,digest TEXT NOT NULL,receipt TEXT NOT NULL)",
                "CREATE INDEX execution_state ON executions(state)", "CREATE INDEX detail_expiry ON details(expired,expires)", "CREATE INDEX quota_time ON quota(charged_at)",
                "CREATE TRIGGER execution_immutable BEFORE UPDATE OF nonce,marker,created,source_nonce ON executions BEGIN SELECT RAISE(ABORT,'immutable reminder intent'); END",
                "CREATE TRIGGER executions_no_delete BEFORE DELETE ON executions BEGIN SELECT RAISE(ABORT,'immutable intent'); END",
                "CREATE TRIGGER details_no_delete BEFORE DELETE ON details BEGIN SELECT RAISE(ABORT,'immutable detail record'); END",
                "CREATE TRIGGER key_guard_delete BEFORE DELETE ON execution_keys WHEN COALESCE((SELECT value FROM metadata WHERE key='expiring_nonce'),'')<>OLD.nonce BEGIN SELECT RAISE(ABORT,'protected key'); END",
                "CREATE TRIGGER audit_no_update BEFORE UPDATE ON audit BEGIN SELECT RAISE(ABORT,'append only'); END", "CREATE TRIGGER audit_no_delete BEFORE DELETE ON audit BEGIN SELECT RAISE(ABORT,'append only'); END",
                "CREATE TRIGGER quota_no_update BEFORE UPDATE ON quota BEGIN SELECT RAISE(ABORT,'immutable quota'); END", "CREATE TRIGGER quota_no_delete BEFORE DELETE ON quota BEGIN SELECT RAISE(ABORT,'immutable quota'); END",
                "CREATE TRIGGER assessment_no_update BEFORE UPDATE ON assessments BEGIN SELECT RAISE(ABORT,'immutable assessment'); END", "CREATE TRIGGER assessment_no_delete BEFORE DELETE ON assessments BEGIN SELECT RAISE(ABORT,'immutable assessment'); END",
                "CREATE TRIGGER detail_payload_immutable BEFORE UPDATE OF nonce,payload_cipher,captured,expires ON details BEGIN SELECT RAISE(ABORT,'immutable detail'); END",
                "CREATE TRIGGER detail_no_unexpire BEFORE UPDATE OF expired ON details WHEN OLD.expired=1 AND NEW.expired<>1 BEGIN SELECT RAISE(ABORT,'expired'); END",
                "CREATE TRIGGER key_no_update BEFORE UPDATE ON execution_keys BEGIN SELECT RAISE(ABORT,'immutable key'); END",
                "CREATE TRIGGER identities_no_delete BEFORE DELETE ON identities BEGIN SELECT RAISE(ABORT,'immutable identity'); END",
                "CREATE TRIGGER identity_id_immutable BEFORE UPDATE OF id,kind ON identities BEGIN SELECT RAISE(ABORT,'immutable identity'); END",
                "CREATE TRIGGER key_no_resurrection BEFORE INSERT ON execution_keys WHEN EXISTS(SELECT 1 FROM details WHERE nonce=NEW.nonce AND expired=1) BEGIN SELECT RAISE(ABORT,'expired key'); END",
                "CREATE TRIGGER nonce_disjoint BEFORE INSERT ON executions WHEN EXISTS(SELECT 1 FROM assessments WHERE nonce=NEW.nonce) BEGIN SELECT RAISE(ABORT,'nonce conflict'); END",
                "CREATE TRIGGER assessment_disjoint BEFORE INSERT ON assessments WHEN EXISTS(SELECT 1 FROM executions WHERE nonce=NEW.nonce) BEGIN SELECT RAISE(ABORT,'nonce conflict'); END"
            ] { try execute(sql) }
            try setMetadata("domain", "reminders"); try setMetadata("resource", "reminders"); try setMetadata("recovery_storage_version", "reminders-1"); try setMetadata("installation_id", UUID().uuidString)
            try setMetadata("policy", try WriteSafetyPolicy.defaults.json.text()); try setMetadata("policy_revision", "0"); try setMetadata("policy_adopted", "false")
        }
    }
    func identity(kind: String, nativeID: String, listID: String = "") throws -> String {
        guard ["list", "reminder"].contains(kind), !nativeID.isEmpty else { throw CoreError("identity_missing", "Invalid Reminders binding") }
        if let row = try rows("SELECT id FROM identities WHERE kind=? AND native_id=? AND list_native_id=?", [kind, nativeID, listID]).first { return row[0] }
        let id = UUID().uuidString; try execute("INSERT INTO identities VALUES(?,?,?,?)", [id, kind, nativeID, listID]); return id
    }
    func resolve(_ id: String, kind: String) throws -> (nativeID: String, listID: String) {
        guard let row = try rows("SELECT native_id,list_native_id FROM identities WHERE id=? AND kind=?", [id, kind]).first else { throw CoreError("identity_missing", "Reminder identity no longer resolves; query again") }; return (row[0], row[1])
    }
    func crypt(_ value: JSON, key: Data, nonce: String, field: String) throws -> String {
        try AES.GCM.seal(value.data(), using: SymmetricKey(data: key), authenticating: Data(("reminders:v1:" + nonce + ":" + field).utf8)).combined!.base64EncodedString()
    }
    func secret(_ nonce: String, field: String) throws -> JSON? {
        guard ["payload_cipher", "result_cipher"].contains(field), let row = try rows("SELECT d." + field + ",k.key FROM details d JOIN execution_keys k USING(nonce) WHERE d.nonce=? AND d.expired=0", [nonce]).first else { return nil }
        guard let bytes = Data(base64Encoded: row[0]), let key = Data(base64Encoded: row[1]), key.count == 32 else { throw CoreError("state_corrupt", "Invalid encrypted Reminders detail") }
        do { return try JSON.parse(AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: SymmetricKey(data: key), authenticating: Data(("reminders:v1:" + nonce + ":" + field).utf8))) }
        catch { throw CoreError("state_corrupt", "Reminders detail authentication failed") }
    }
    func execution(_ nonce: String) throws -> ReminderExecution? {
        guard let row = try rows("SELECT marker,state,result,created FROM executions WHERE nonce=?", [nonce]).first else { return nil }
        let marker = try JSON.parse(Data(row[0].utf8)), payload = try secret(nonce, field: "payload_cipher")
        return ReminderExecution(nonce: nonce, state: row[1], created: row[3], payload: payload ?? marker, result: try secret(nonce, field: "result_cipher") ?? JSON.parse(Data(row[2].utf8)), marker: marker, detailsAvailable: payload != nil)
    }
    func minimal(_ value: JSON, nonce: String, state: String) -> JSON {
        var result: [String: JSON] = ["nonce": .string(nonce), "state": .string(state)]
        for key in ["action", "audit_sequence", "reminder_id", "source_change_id", "outcome", "resolution_source", "verification", "reconciliation_nonce", "assessment_digest", "diagnostic", "execution_evidence"] where value[key] != .null { result[key] = value[key] }
        if state == "not_applied" { result["message"] = value["message"] }
        return .object(result)
    }
    private func policy() throws -> WriteSafetyPolicy {
        if let value = try WriteSafetyPolicy.read(directory: directory) { return value }
        guard try metadata("policy_adopted") != "true" else { throw CoreError("write_safety_configuration", "Restore the adopted Reminders write-safety policy") }; return .defaults
    }
    func safety(action: String, now: Date, policy: WriteSafetyPolicy? = nil) throws -> JSON {
        let chosen = try policy ?? self.policy(), effective = max(now, try metadata("quota_highwater").map(parseDate) ?? now)
        let records = try rows("SELECT action,charged_at FROM quota WHERE charged_at>?", [iso(effective.addingTimeInterval(-86400))]).map { ($0[0], try parseDate($0[1])) }
        var usage: [String: JSON] = [:], allowed = true
        for (name, seconds, limit, deleteOnly) in [("delete_hour", 3600, chosen.deleteHour, true), ("delete_day", 86400, chosen.deleteDay, true), ("destructive_hour", 3600, chosen.destructiveHour, false), ("destructive_day", 86400, chosen.destructiveDay, false)] {
            let count = records.filter { (!deleteOnly || $0.0 == "delete") && $0.1 > effective.addingTimeInterval(-Double(seconds)) }.count
            usage[name] = .object(["limit": .int(limit), "used": .int(count), "remaining": .int(max(0, limit - count))])
            if action != "create" && (!deleteOnly || action == "delete") && count >= limit { allowed = false }
        }
        return .object(["allowed_now": .bool(allowed), "advisory": .bool(true), "policy": chosen.json, "usage": .object(usage), "effective_at": .string(iso(effective))])
    }
    func claim(nonce: String, payload: JSON, now: Date) throws -> Int {
        try transaction {
            guard try execution(nonce) == nil else { throw CoreError("nonce_conflict", "Reminders nonce already consumed") }
            try assertNoConflict(payload)
            guard let action = payload["action"].string, ["create", "modify", "complete", "reopen", "delete"].contains(action) else { throw CoreError("invalid_preview", "Invalid reminder action") }
            let chosen = try policy(), advisory = try safety(action: action, now: now, policy: chosen)
            guard advisory["allowed_now"] == .bool(true) else { throw CoreError("write_safety_limit", "Reminders write allowance exhausted; wait or inspect the protected local policy") }
            let policyText = try chosen.json.text()
            if try metadata("policy") != policyText || (WriteSafetyPolicy.read(directory: directory) != nil && metadata("policy_adopted") != "true") {
                try setMetadata("policy", policyText); try setMetadata("policy_adopted", "true")
                _ = try appendInside("write_safety_policy_changed", nonce: nil, payload: .object(["policy": chosen.json]), origin: "local_configuration")
            }
            let source = payload["rollback"]["source_change_id"].string
            if let source { try assertRecoveryUnused(source) }
            if action != "create" {
                try execute("INSERT INTO quota VALUES(?,?,?)", [nonce, action == "delete" ? "delete" : "modify", advisory["effective_at"].string!]); try setMetadata("quota_highwater", advisory["effective_at"].string!)
                _ = try appendInside("write_safety_charged", nonce: nonce, payload: .object(["action": .string(action)]))
            }
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, captured = max(now, try metadata("retention_highwater").map(parseDate) ?? now)
            try setMetadata("retention_highwater", iso(captured))
            let days = try retentionDays(), marker = try reminderMarker(payload, nonce: nonce)
            let intent: JSON = .object(["nonce": .string(nonce), "state": .string("intent_recorded"), "action": payload["action"]])
            try execute("INSERT INTO execution_keys VALUES(?,?)", [nonce, key.base64EncodedString()])
            try execute("INSERT INTO details VALUES(?,?,?,?,?,0)", [nonce, try crypt(payload, key: key, nonce: nonce, field: "payload_cipher"), try crypt(intent, key: key, nonce: nonce, field: "result_cipher"), iso(captured), iso(captured.addingTimeInterval(Double(days) * 86400))])
            try execute("INSERT INTO executions VALUES(?,?,?, ?,?,?)", [nonce, try marker.text(), "intent_recorded", try intent.text(), iso(now), source ?? ""])
            return try appendInside("write_intent", nonce: nonce, payload: marker)
        }
    }
    func finish(nonce: String, state: String, result: JSON, event: String, origin: String = "chatgpt_host_policy") throws {
        try transaction {
            guard ["applied", "unknown", "reconciled"].contains(state), result["nonce"] == .string(nonce), result["state"] == .string(state), let old = try execution(nonce), result["action"] == old.marker["action"], (old.state == "intent_recorded" && ["applied", "unknown"].contains(state) || old.state == "unknown" && state == "reconciled"), let row = try rows("SELECT key FROM execution_keys WHERE nonce=?", [nonce]).first, let key = Data(base64Encoded: row[0]) else { throw CoreError("audit_unavailable", "Cannot persist Reminders outcome") }
            try execute("UPDATE details SET result_cipher=? WHERE nonce=?", [try crypt(result, key: key, nonce: nonce, field: "result_cipher"), nonce])
            try execute("UPDATE executions SET state=?,result=? WHERE nonce=?", [state, try minimal(result, nonce: nonce, state: state).text(), nonce])
            _ = try appendInside(event, nonce: nonce, payload: result, origin: origin)
        }
    }
    @discardableResult func append(_ event: String, nonce: String?, payload: JSON) throws -> Int { try transaction { try appendInside(event, nonce: nonce, payload: payload) } }
    @discardableResult func appendInside(_ event: String, nonce: String?, payload: JSON, origin: String = "chatgpt_host_policy") throws -> Int {
        let last = try rows("SELECT sequence,hash FROM audit ORDER BY sequence DESC LIMIT 1").first, sequence = (last.flatMap { Int($0[0]) } ?? 0) + 1, previous = last?[1] ?? String(repeating: "0", count: 64)
        var safe: [String: JSON] = [:]
        for key in ["resource", "version", "action", "state", "list_id", "reminder_id", "source_change_id", "payload_digest", "outcome", "resolution_source", "verification", "reconciliation_nonce", "assessment_digest", "diagnostic", "execution_evidence", "policy", "observations"] where payload[key] != .null { safe[key] = payload[key] }
        safe["detail_digest"] = .string(digest(try payload.data()))
        if let nonce, let state = payload["state"].string, ["applied", "unknown", "not_applied", "reconciled"].contains(state) { safe["minimal_digest"] = .string(digest(try minimal(payload, nonce: nonce, state: state).data())) }
        let body: JSON = .object(["version": .int(1), "sequence": .int(sequence), "event": .string(event), "nonce": .optional(nonce), "timestamp": .string(iso(Date())), "approval_source": .string(origin), "approval_evidence": .string("not_provided"), "payload": .object(safe)])
        try execute("INSERT INTO audit VALUES(?,?,?,?)", [String(sequence), try body.text(), previous, digest(Data(previous.utf8) + (try body.data()))]); return sequence
    }
    func verifyAudit() throws {
        var previous = String(repeating: "0", count: 64), sequence = 0, evidence: [String: [JSON]] = [:], checkpoint: JSON = .array([])
        for row in try rows("SELECT sequence,body,previous_hash,hash FROM audit ORDER BY sequence") {
            sequence += 1; let body = try JSON.parse(Data(row[1].utf8))
            guard Int(row[0]) == sequence, body["sequence"] == .int(sequence), row[2] == previous, row[3] == digest(Data(previous.utf8) + Data(row[1].utf8)) else { throw CoreError("audit_corrupt", "Reminders audit chain failed") }; previous = row[3]
            if body["event"] == .string("observation_checkpoint") { try validateObservationSnapshot(body["payload"]["observations"]); checkpoint = body["payload"]["observations"] }
            if let nonce = body["nonce"].string { evidence[nonce, default: []].append(body) }
        }
        try validateObservations(checkpoint: checkpoint); try validateHistory(audits: evidence)
    }
    private func retentionDays() throws -> Int {
        let path = directory.appendingPathComponent("recovery-policy.json").path, fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return 5 }; throw CoreError("recovery_configuration", "Cannot read Reminders retention policy") }; defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= 16384 else { throw CoreError("recovery_configuration", "Unsafe Reminders retention policy") }
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while true { let count = read(fd, &bytes, bytes.count); if count == 0 { break }; guard count > 0 else { throw CoreError("recovery_configuration", "Reminders retention read failed") }; data.append(contentsOf: bytes.prefix(count)); guard data.count <= 16384 else { throw CoreError("recovery_configuration", "Reminders retention policy too large") } }
        let value = try JSON.parse(data); _ = try Arguments(value, allowed: ["version", "retention_days"], required: ["version", "retention_days"])
        guard value["version"] == .int(1), let days = value["retention_days"].integer, (1...365).contains(days) else { throw CoreError("recovery_configuration", "Invalid Reminders retention policy") }; return days
    }
    func expire(now: Date) throws {
        try transaction {
            let effective = max(now, try metadata("retention_highwater").map(parseDate) ?? now); try setMetadata("retention_highwater", iso(effective))
            var held = Set(try rows("SELECT nonce FROM executions WHERE state IN ('unknown','intent_recorded')").map { $0[0] }), pending = Array(held)
            while let nonce = pending.popLast() {
                guard let row = try rows("SELECT source_nonce FROM executions WHERE nonce=?", [nonce]).first else { throw CoreError("state_corrupt", "Missing held Reminders source") }
                if !row[0].isEmpty, held.insert(row[0]).inserted { pending.append(row[0]) }
            }
            for row in try rows("SELECT nonce FROM details WHERE expired=0 AND expires<=?", [iso(effective)]) where !held.contains(row[0]) {
                try setMetadata("expiring_nonce", row[0]); try execute("DELETE FROM execution_keys WHERE nonce=?", [row[0]]); try setMetadata("expiring_nonce", ""); try execute("UPDATE details SET expired=1 WHERE nonce=?", [row[0]])
                _ = try appendInside("details_expired", nonce: row[0], payload: .object([:]), origin: "native_maintenance")
            }
        }
    }
}
