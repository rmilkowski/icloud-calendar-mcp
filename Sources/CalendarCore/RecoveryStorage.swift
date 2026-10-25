import Foundation
import CryptoKit
import Darwin

extension StateStore {
    public func recoveryMetadata() throws -> JSON {
        .object(["storage_version": .int(6), "execution_count": .int(try rows("SELECT nonce FROM executions").count), "retained_detail_count": .int(try rows("SELECT nonce FROM execution_keys").count), "expired_detail_count": .int(try rows("SELECT nonce FROM execution_details WHERE expired=1").count), "unresolved_count": .int(try rows("SELECT nonce FROM executions WHERE state IN ('intent_recorded','unknown')").count), "audit_record_count": .int(try rows("SELECT sequence FROM audit").count), "cleanup_complete": .bool(try metadata("recovery_cleanup_pending") != "true")])
    }
    /// Fixed local configuration. Neither transport nor signed previews can change retention.
    public func recoveryPolicy() throws -> JSON {
        let path = directory.appendingPathComponent("recovery-policy.json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return .object(["version": .int(1), "retention_days": .int(5)]) }
            throw CoreError("recovery_configuration", "Cannot safely read local recovery-policy.json")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096 else {
            throw CoreError("recovery_configuration", "recovery-policy.json must be an owned single-link regular file, mode 0600, at most 4 KiB")
        }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, count <= 4096 else { throw CoreError("recovery_configuration", "Cannot read bounded recovery policy") }
        let json = try JSON.parse(Data(bytes.prefix(count)))
        guard let object = json.object, Set(object.keys) == ["version", "retention_days"], json["version"] == .int(1),
              let days = json["retention_days"].integer, (1...365).contains(days) else {
            throw CoreError("recovery_configuration", "Use recovery-policy.json version 1 and integer retention_days from 1 through 365")
        }
        return json
    }
    func encrypted(_ value: JSON, key: SymmetricKey, nonce: String, field: String) throws -> String {
        let sealed = try AES.GCM.seal(value.data(), using: key, authenticating: Data((nonce + ":" + field).utf8))
        guard let combined = sealed.combined else { throw CoreError("audit_unavailable", "Cannot seal recovery details") }
        return combined.base64EncodedString()
    }
    func secret(nonce: String, column: String) throws -> JSON? {
        guard ["payload_cipher", "result_cipher"].contains(column) else { throw CoreError("state_corrupt", "Invalid recovery field") }
        guard let row = try rows("SELECT d.\(column),k.key FROM execution_details d JOIN execution_keys k ON k.nonce=d.nonce WHERE d.nonce=? AND d.expired=0", [nonce]).first else { return nil }
        guard let key = Data(base64Encoded: row[1]), key.count == 32, let cipher = Data(base64Encoded: row[0]) else { throw CoreError("state_corrupt", "Invalid recovery ciphertext") }
        do {
            return try JSON.parse(AES.GCM.open(AES.GCM.SealedBox(combined: cipher), using: SymmetricKey(data: key), authenticating: Data((nonce + ":" + column).utf8)))
        } catch { throw CoreError("state_corrupt", "Recovery detail authentication failed") }
    }
    func payloadMarker(_ payload: JSON) throws -> JSON {
        var value: [String: JSON] = ["storage_version": .int(2), "action": payload["action"], "payload_digest": .string(digest(try payload.data()))]
        value["calendar_id"] = payload["calendar"]["id"]
        value["scope"] = payload["scope"]
        if payload["version"] == .int(7) { value["all_day_version"] = .int(7) }
        if [.int(5), .int(6)].contains(payload["version"]) { value["future_boundary"] = payload["future"]["boundary"]; value["future_anchor_id"] = payload["future"]["first_anchor"]["id"] }
        if payload["version"] == .int(6) { value["future_version"] = .int(6); value["future_reference_id"] = payload["future"]["reference"]["id"]; value["future_kind"] = .string(payload["action"] == .string("delete") ? "termination" : "independent_tail_copy") }
        if payload["version"] == .int(4) { value["series_anchor_id"] = payload["before"]["id"] }
        if let id = payload["before"]["id"].string { value["event_id"] = .string(id) }
        if let id = payload["event_id"].string { value["event_id"] = .string(id) }
        if let sources = payload["rollback"]["source_change_ids"].array {
            value["rollback_of"] = .array(sources)
            if let first = sources.first?.string, let row = try rows("SELECT payload FROM executions WHERE nonce=?", [first]).first { value["event_id"] = try JSON.parse(Data(row[0].utf8))["event_id"] }
        }
        return .object(value)
    }
    func minimalResult(nonce: String, state: String, result: JSON) -> JSON {
        var value: [String: JSON] = ["storage_version": .int(2), "nonce": .string(nonce), "state": .string(state)]
        for key in ["action", "audit_sequence", "outcome", "rollback_of", "event_id", "parent_nonce", "completed", "remaining", "stopped_reason"] where result[key] != .null { value[key] = result[key] }
        return .object(value)
    }
    func storeIntent(nonce: String, payload: JSON, result: JSON, now: Date, marker: JSON) throws {
        let days = try recoveryPolicy()["retention_days"].integer!
        let captured = max(now, try metadata("recovery_clock_highwater").map(parseDate) ?? now)
        let key = SymmetricKey(size: .bits256), expiry = captured.addingTimeInterval(Double(days) * 86400)
        try execute("INSERT INTO execution_keys(nonce,key) VALUES(?,?)", [nonce, key.withUnsafeBytes { Data($0).base64EncodedString() }])
        try execute("INSERT INTO execution_details(nonce,payload_cipher,result_cipher,captured,expires,expired) VALUES(?,?,?,?,?,0)", [nonce, try encrypted(payload, key: key, nonce: nonce, field: "payload_cipher"), try encrypted(result, key: key, nonce: nonce, field: "result_cipher"), iso(captured), iso(expiry)])
        try execute("INSERT INTO executions(nonce,payload,state,result,created) VALUES(?,?,'intent_recorded',?,?)", [nonce, try marker.text(), try minimalResult(nonce: nonce, state: "intent_recorded", result: result).text(), iso(now)])
    }
    func storeResult(nonce: String, state: String, result: JSON) throws {
        guard let row = try rows("SELECT key FROM execution_keys WHERE nonce=?", [nonce]).first,
              let key = Data(base64Encoded: row[0]), key.count == 32 else { throw CoreError("audit_unavailable", "Recovery key unavailable for unresolved execution") }
        try execute("UPDATE execution_details SET result_cipher=? WHERE nonce=?", [try encrypted(result, key: SymmetricKey(data: key), nonce: nonce, field: "result_cipher"), nonce])
        try execute("UPDATE executions SET state=?,result=? WHERE nonce=?", [state, try minimalResult(nonce: nonce, state: state, result: result).text(), nonce])
        if state == "applied", let sources = result["rollback_of"].array {
            for source in sources { guard let source = source.string else { throw CoreError("state_corrupt", "Invalid rollback lineage") }; try execute("INSERT INTO recovery_links(source_nonce,rollback_nonce) VALUES(?,?)", [source, nonce]) }
        }
    }
    func safeAuditPayload(event: String, nonce: String?, payload: JSON) -> JSON {
        if event.hasPrefix("write_safety_") || event.contains("credential") || event == "recovery_migration_checkpoint" || event == "details_expired" || event == "commit_observation_checkpoint" { return payload }
        var result: [String: JSON] = [:]
        for key in ["storage_version", "state", "action", "audit_sequence", "code", "op", "outcome", "rollback_of", "event_id", "parent_nonce", "stopped_reason", "resolution_source", "verification", "reconciliation_nonce"] where payload[key] != .null { result[key] = payload[key] }
        if let nonce { result["detail_reference"] = .string(nonce) }
        if let data = try? payload.data() { result["detail_digest"] = .string(digest(data)) }
        return .object(result)
    }
    func recoveryHeldNonces() throws -> Set<String> {
        // Start with indexed unresolved executions; fetch only their transitive
        // rollback ancestors by primary key, never decode resolved history.
        let unresolved = try rows("SELECT nonce,payload FROM executions WHERE state IN ('intent_recorded','unknown')")
        var pinned = Set(unresolved.map { $0[0] }), pending = unresolved
        while let row = pending.popLast() {
            let marker = try JSON.parse(Data(row[1].utf8))
            for source in marker["rollback_of"].array?.compactMap(\.string) ?? [] where pinned.insert(source).inserted {
                guard let ancestor = try rows("SELECT nonce,payload FROM executions WHERE nonce=?", [source]).first else { throw CoreError("state_corrupt", "Missing unresolved rollback ancestor") }
                pending.append(ancestor)
            }
        }
        return pinned
    }
    public func expireRecoveryDetails(now: Date) throws {
        try transaction {
            let previous = try metadata("recovery_clock_highwater").map(parseDate), effective = max(now, previous ?? now)
            try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('recovery_clock_highwater',?)", [iso(effective)])
            guard !(try rows("SELECT nonce FROM execution_details WHERE expired=0 AND expires<=? LIMIT 1", [iso(effective)])).isEmpty else { return }
            let pinned = try recoveryHeldNonces()
            for row in try rows("SELECT nonce,expires FROM execution_details WHERE expired=0 AND expires<=?", [iso(effective)]) where !pinned.contains(row[0]) {
                try execute("DELETE FROM execution_keys WHERE nonce=?", [row[0]])
                try execute("UPDATE execution_details SET expired=1 WHERE nonce=?", [row[0]])
                guard let resultRow = try rows("SELECT result FROM executions WHERE nonce=?", [row[0]]).first,
                      var result = try JSON.parse(Data(resultRow[0].utf8)).object else { throw CoreError("state_corrupt", "Missing expiry outcome") }
                result["details_expired"] = .bool(true)
                try execute("UPDATE executions SET result=? WHERE nonce=?", [try JSON.object(result).text(), row[0]])
                _ = try appendInsideTransaction(event: "details_expired", nonce: row[0], payload: .object(["expires_at": .string(row[1])]))
            }
        }
    }
    func migrateRecoveryStorage() throws {
        if let version = try metadata("recovery_storage_version"), !["2", "3", "4", "5", "6"].contains(version) { throw CoreError("state_version", "Unsupported recovery storage version") }
        try execute("CREATE TABLE IF NOT EXISTS execution_details(nonce TEXT PRIMARY KEY,payload_cipher TEXT NOT NULL,result_cipher TEXT NOT NULL,captured TEXT NOT NULL,expires TEXT NOT NULL,expired INTEGER NOT NULL CHECK(expired IN (0,1)))")
        try execute("CREATE INDEX IF NOT EXISTS execution_details_expiry ON execution_details(expired,expires)")
        try execute("CREATE TABLE IF NOT EXISTS execution_keys(nonce TEXT PRIMARY KEY,key TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS recovery_links(source_nonce TEXT PRIMARY KEY,rollback_nonce TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS legacy_audit_details(sequence INTEGER PRIMARY KEY,nonce TEXT NOT NULL,cipher TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS legacy_audit_manifest(sequence INTEGER PRIMARY KEY,body TEXT NOT NULL)")
        try verifyAudit()
        let legacy = try rows("SELECT nonce,payload,state,result,created FROM executions WHERE COALESCE(json_extract(payload,'$.storage_version'),0)<>2")
        guard try !["3", "4", "5", "6"].contains(metadata("recovery_storage_version") ?? "") || legacy.isEmpty else { throw CoreError("state_corrupt", "Writer-floor v3/v4/v5/v6 requires existing encrypted v2 journal encoding; repair forward without rewriting authoritative history") }
        if try !["2", "3", "4", "5", "6"].contains(metadata("recovery_storage_version") ?? "") || !legacy.isEmpty {
            let oldAudit = try rows("SELECT sequence,hash FROM audit ORDER BY sequence DESC LIMIT 1").first
            let oldBodies = try rows("SELECT sequence,body,previous_hash,hash FROM audit ORDER BY sequence")
            let conversion = digest(Data(try JSON.array(legacy.map { .array($0.map(JSON.string)) }).text().utf8))
            try transaction {
                try execute("DROP TRIGGER IF EXISTS payload_immutable")
                try execute("DROP TRIGGER IF EXISTS audit_no_delete")
                try execute("DELETE FROM audit")
                for row in legacy {
                    let payload = try JSON.parse(Data(row[1].utf8)), result = try JSON.parse(Data(row[3].utf8)), captured = try parseDate(row[4])
                    guard ["create", "modify", "delete"].contains(payload["action"].string ?? "") else { throw CoreError("state_corrupt", "Invalid legacy execution action") }
                    let key = SymmetricKey(size: .bits256), expiry = captured.addingTimeInterval(Double(try recoveryPolicy()["retention_days"].integer!) * 86400)
                    try execute("INSERT INTO execution_keys(nonce,key) VALUES(?,?)", [row[0], key.withUnsafeBytes { Data($0).base64EncodedString() }])
                    try execute("INSERT INTO execution_details VALUES(?,?,?,?,?,0)", [row[0], try encrypted(payload, key: key, nonce: row[0], field: "payload_cipher"), try encrypted(result, key: key, nonce: row[0], field: "result_cipher"), iso(captured), iso(expiry)])
                    try execute("UPDATE executions SET payload=?,result=? WHERE nonce=?", [try payloadMarker(payload).text(), try minimalResult(nonce: row[0], state: row[2], result: result).text(), row[0]])
                }
                for record in oldBodies {
                    let body = try JSON.parse(Data(record[1].utf8))
                    if let nonce = body["nonce"].string, let row = try rows("SELECT key FROM execution_keys WHERE nonce=?", [nonce]).first, let key = Data(base64Encoded: row[0]) {
                        try execute("INSERT INTO legacy_audit_details(sequence,nonce,cipher) VALUES(?,?,?)", [record[0], nonce, try encrypted(body, key: SymmetricKey(data: key), nonce: nonce, field: "legacy_audit_" + record[0])])
                    }
                    var manifest: [String: JSON] = ["original_sequence": .string(record[0]), "previous_hash": .string(record[2]), "hash": .string(record[3])]
                    for key in ["event_id", "timestamp", "event", "nonce", "approval_source", "approval_evidence"] { manifest[key] = body[key] }
                    try execute("INSERT INTO legacy_audit_manifest VALUES(?,?)", [record[0], try JSON.object(manifest).text()])
                }
                try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('recovery_storage_version','2')")
                try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('recovery_cleanup_pending','true')")
                _ = try appendInsideTransaction(event: "recovery_migration_checkpoint", nonce: nil, payload: .object(["legacy_record_count": .int(oldAudit.flatMap { Int($0[0]) } ?? 0), "legacy_tail_hash": .string(oldAudit?[1] ?? String(repeating: "0", count: 64)), "conversion_digest": .string(conversion), "converted_executions": .int(legacy.count), "legacy_manifest_digest": .string(digest(try JSON.array(rows("SELECT body FROM legacy_audit_manifest ORDER BY sequence").map { .string($0[0]) }).data()))]))
                try execute("CREATE TRIGGER payload_immutable BEFORE UPDATE OF nonce,payload,created ON executions BEGIN SELECT RAISE(ABORT,'immutable payload'); END")
                try execute("CREATE TRIGGER audit_no_delete BEFORE DELETE ON audit BEGIN SELECT RAISE(ABORT,'append only'); END")
                try installRecoveryFences()
            }
        }
        try installRecoveryFences()
        if try metadata("recovery_cleanup_pending") == "true" {
            // SQLite scrubbing is best effort; copies, backups and SSD history are outside this boundary.
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try execute("VACUUM")
            try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('recovery_cleanup_pending','false')")
        }
        // Metadata v6 is a forward-only writer compatibility floor. The encrypted
        // detail/marker encoding remains v2; older helpers reject before serving.
        if try metadata("recovery_storage_version") != "6" {
            try transaction { try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('recovery_storage_version','6')") }
        }
    }
    func verifyLegacyManifest() throws {
        guard let checkpoint = try rows("SELECT body FROM audit ORDER BY sequence LIMIT 1").first else { return }
        let expected = try JSON.parse(Data(checkpoint[0].utf8))["payload"]["legacy_manifest_digest"]
        if expected != .null {
            let actual = digest(try JSON.array(rows("SELECT body FROM legacy_audit_manifest ORDER BY sequence").map { .string($0[0]) }).data())
            guard expected == .string(actual) else { throw CoreError("audit_corrupt", "Legacy audit manifest differs from migration checkpoint") }
        }
    }
    func installRecoveryFences() throws {
        try execute("CREATE TRIGGER IF NOT EXISTS execution_v2_insert BEFORE INSERT ON executions WHEN COALESCE(json_extract(NEW.payload,'$.storage_version'),0)<>2 OR COALESCE(json_extract(NEW.result,'$.storage_version'),0)<>2 BEGIN SELECT RAISE(ABORT,'requires recovery storage v2'); END")
        try execute("CREATE TRIGGER IF NOT EXISTS execution_v2_result BEFORE UPDATE OF result ON executions WHEN COALESCE(json_extract(NEW.result,'$.storage_version'),0)<>2 BEGIN SELECT RAISE(ABORT,'requires recovery storage v2'); END")
        try execute("CREATE TRIGGER IF NOT EXISTS recovery_expiry_irreversible BEFORE UPDATE OF expired ON execution_details WHEN OLD.expired=1 AND NEW.expired<>1 BEGIN SELECT RAISE(ABORT,'expired recovery details'); END")
        try execute("CREATE TRIGGER IF NOT EXISTS recovery_key_no_resurrection BEFORE INSERT ON execution_keys WHEN EXISTS(SELECT 1 FROM execution_details WHERE nonce=NEW.nonce AND expired=1) BEGIN SELECT RAISE(ABORT,'expired recovery key'); END")
        try execute("CREATE TRIGGER IF NOT EXISTS recovery_payload_immutable BEFORE UPDATE OF nonce,payload_cipher,captured,expires ON execution_details BEGIN SELECT RAISE(ABORT,'immutable recovery payload'); END")
    }
}
