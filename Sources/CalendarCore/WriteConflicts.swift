import Foundation

/// Native journal evidence, never part of a signed preview or its digest. A group
/// is the provider's calendarItemIdentifier in its native calendar, across every
/// occurrence and detached binding known to the integration.
struct WriteConflictScope {
    struct Group: Hashable {
        let calendar: String
        let item: String
        var json: JSON { .object(["calendar": .string(calendar), "item": .string(item)]) }
    }
    var calendar: String?
    var groups: Set<Group> = []
    var eventIDs: Set<String> = []
    var nonces: Set<String> = []
    var cutoff = 0
    var existingTarget = false
    var complete = true

    var json: JSON {
        .object(["version": .int(1), "calendar": .optional(calendar),
                 "groups": .array(groups.sorted { ($0.calendar, $0.item) < ($1.calendar, $1.item) }.map(\.json)),
                 "event_ids": .array(eventIDs.sorted().map(JSON.string)),
                 "nonces": .array(nonces.sorted().map(JSON.string)), "identity_cutoff": .int(cutoff),
                 "existing_target": .bool(existingTarget), "complete": .bool(complete)])
    }
    init() {}
    init(json: JSON) throws {
        let keys: Set<String> = ["version", "calendar", "groups", "event_ids", "nonces", "identity_cutoff", "existing_target", "complete"]
        guard let object = json.object, Set(object.keys) == keys, json["version"] == .int(1),
              json["calendar"] == .null || json["calendar"].string?.isEmpty == false,
              let cutoff = json["identity_cutoff"].integer, cutoff >= 0,
              let existing = json["existing_target"].boolean, let complete = json["complete"].boolean,
              let groups = json["groups"].array, let ids = json["event_ids"].array, let nonces = json["nonces"].array,
              ids.allSatisfy({ $0.string.flatMap(UUID.init(uuidString:)) != nil }), nonces.allSatisfy({ $0.string.flatMap(UUID.init(uuidString:)) != nil }) else {
            throw CoreError("unresolved_write", "Stored conflict evidence is malformed; inspect locally")
        }
        self.calendar = json["calendar"].string; self.cutoff = cutoff
        self.existingTarget = existing; self.complete = complete
        eventIDs = Set(ids.compactMap(\.string)); self.nonces = Set(nonces.compactMap(\.string))
        for value in groups {
            guard let group = value.object, Set(group.keys) == ["calendar", "item"],
                  let calendar = value["calendar"].string, !calendar.isEmpty,
                  let item = value["item"].string, !item.isEmpty else {
                throw CoreError("unresolved_write", "Stored native group evidence is malformed; inspect locally")
            }
            self.groups.insert(Group(calendar: calendar, item: item))
        }
        guard self.groups.count == groups.count, eventIDs.count == ids.count, self.nonces.count == nonces.count,
              self.calendar == nil || self.groups.allSatisfy({ $0.calendar == self.calendar }),
              (!complete || (self.calendar != nil && self.groups.allSatisfy({ $0.calendar == self.calendar }) && (!existing || (!eventIDs.isEmpty && !self.groups.isEmpty)))) else {
            throw CoreError("unresolved_write", "Stored conflict evidence is inconsistent; inspect locally")
        }
    }
}

extension StateStore {
    private func conflictCalendar(_ id: String?) throws -> String? {
        guard let id, let row = try rows("SELECT native_id FROM identities WHERE id=? AND kind='calendar'", [id]).first,
              !row[0].isEmpty else { return nil }
        return row[0]
    }
    private func addCurrentBindings(to scope: inout WriteConflictScope) throws {
        for id in scope.eventIDs {
            guard let row = try rows("SELECT native_id,calendar_id FROM identities WHERE id=? AND kind='event'", [id]).first,
                  !row[0].isEmpty, !row[1].isEmpty else { scope.complete = false; continue }
            guard row[1] == scope.calendar else { scope.calendar = nil; scope.complete = false; continue }
            scope.groups.insert(.init(calendar: row[1], item: row[0]))
        }
    }
    /// Legacy history carries no retrospective identity witness. Its trusted
    /// calendar can establish cross-calendar independence only.
    private func singleStoredConflictScope(nonce: String, marker: JSON) throws -> WriteConflictScope {
        var scope: WriteConflictScope
        if marker.object?.keys.contains("conflict_scope") == true {
            scope = try WriteConflictScope(json: marker["conflict_scope"])
            let maximum = Int(try rows("SELECT COALESCE(MAX(rowid),0) FROM identities").first![0]) ?? 0
            let calendar = try conflictCalendar(marker["calendar_id"].string ?? marker["calendar"]["id"].string)
            guard scope.nonces.contains(nonce), scope.cutoff <= maximum,
                  scope.existingTarget == ["modify", "delete"].contains(marker["action"].string ?? ""),
                  scope.calendar == nil || scope.calendar == calendar else {
                throw CoreError("unresolved_write", "Stored conflict evidence disagrees with its immutable execution")
            }
            if marker["scope"] == .string("future") {
                guard !scope.complete, let boundary = marker["future_boundary"].string,
                      iso(try parseDate(boundary)) == boundary, marker["future_anchor_id"].string != nil else {
                    throw CoreError("unresolved_write", "Stored future conflict evidence cannot exhaust provider split groups")
                }
            }
            let retained = try secret(nonce: nonce, column: "payload_cipher")
            for id in [marker["event_id"], marker["series_anchor_id"], marker["future_anchor_id"], marker["future_reference_id"], retained?["future"]["reference"]["id"] ?? .null, retained?["future"]["first_anchor"]["id"] ?? .null, retained?["before"]["id"] ?? .null, retained?["event_id"] ?? .null, retained?["series"]["selected"]["id"] ?? .null] where id != .null {
                guard let id = id.string, scope.eventIDs.contains(id) else { throw CoreError("unresolved_write", "Stored conflict evidence omits an affected identity") }
            }
            for raw in [marker["rollback_of"], retained?["rollback"]["source_change_ids"] ?? .null] where raw != .null {
                guard let sources = raw.array, sources.count <= 25,
                      sources.allSatisfy({ $0.string.flatMap(UUID.init(uuidString:)) != nil && scope.nonces.contains($0.string!) }) else {
                    throw CoreError("unresolved_write", "Stored conflict evidence omits recovery dependencies")
                }
            }
        } else {
            scope = WriteConflictScope(); scope.complete = false
            scope.calendar = try conflictCalendar(marker["calendar_id"].string ?? marker["calendar"]["id"].string)
            if let id = marker["event_id"].string ?? marker["before"]["id"].string { scope.eventIDs.insert(id) }
        }
        scope.nonces.insert(nonce)
        try addCurrentBindings(to: &scope)
        return scope
    }
    private func storedConflictScope(nonce: String, marker: JSON) throws -> WriteConflictScope {
        var scope = try singleStoredConflictScope(nonce: nonce, marker: marker)
        var pending: [(String, JSON, Set<String>)] = [(nonce, marker, [])], visited: Set<String> = []
        while let (current, value, path) = pending.popLast() {
            guard !path.contains(current), path.count < 128, visited.count < 512 else { throw CoreError("unresolved_write", "Recovery dependency evidence is cyclic or exceeds its bound") }
            guard visited.insert(current).inserted else { continue }
            let raw = value["rollback_of"] == .null ? value["rollback"]["source_change_ids"] : value["rollback_of"]
            guard raw == .null || (raw.array != nil && raw.array!.count <= 25 && raw.array!.allSatisfy({ $0.string?.isEmpty == false })) else { throw CoreError("unresolved_write", "Invalid stored recovery dependency evidence") }
            var nextPath = path; nextPath.insert(current)
            for source in raw.array?.compactMap(\.string) ?? [] {
                guard let row = try rows("SELECT payload FROM executions WHERE nonce=?", [source]).first else { throw CoreError("unresolved_write", "Recovery dependency evidence is missing") }
                let sourceMarker = try JSON.parse(Data(row[0].utf8))
                let ancestor = try singleStoredConflictScope(nonce: source, marker: sourceMarker)
                scope.eventIDs.formUnion(ancestor.eventIDs); scope.groups.formUnion(ancestor.groups); scope.nonces.formUnion(ancestor.nonces)
                scope.complete = scope.complete && ancestor.complete
                if scope.calendar != ancestor.calendar { scope.calendar = nil; scope.complete = false }
                pending.append((source, sourceMarker, nextPath))
            }
        }
        return scope
    }
    /// Payloads reach this boundary only after native authentication. The
    /// transaction rebuilds this evidence before quota, intent, or provider work.
    func writeConflictScope(payload: JSON, nonce: String? = nil) throws -> WriteConflictScope {
        var scope = WriteConflictScope()
        scope.calendar = try conflictCalendar(payload["calendar"]["id"].string)
        if scope.calendar == nil { scope.complete = false }
        scope.cutoff = Int(try rows("SELECT COALESCE(MAX(rowid),0) FROM identities").first![0]) ?? 0
        scope.existingTarget = ["modify", "delete"].contains(payload["action"].string ?? "")
        if let nonce = nonce ?? payload["nonce"].string { scope.nonces.insert(nonce) }
        for value in [payload["before"]["id"], payload["event_id"], payload["series"]["selected"]["id"], payload["future"]["first_anchor"]["id"], payload["future"]["reference"]["id"]] {
            if let id = value.string { scope.eventIDs.insert(id) }
        }
        // Source closure is authoritative journal history, including every
        // original identity which a successful rollback may rebind.
        func sourceIDs(_ value: JSON) throws -> [String] {
            if value == .null { return [] }
            guard let ids = value.array, ids.count <= 25, ids.allSatisfy({ $0.string.flatMap(UUID.init(uuidString:)) != nil }) else {
                throw CoreError("unresolved_write", "Invalid recovery dependency evidence")
            }
            return ids.compactMap(\.string)
        }
        var pending = try sourceIDs(payload["rollback"]["source_change_ids"]).map { ($0, Set<String>()) }
        var visited: Set<String> = []
        while let (source, path) = pending.popLast() {
            guard !path.contains(source), path.count < 128, visited.count < 512 else { throw CoreError("unresolved_write", "Recovery dependency evidence is cyclic or exceeds its bound") }
            guard visited.insert(source).inserted else { continue }
            scope.nonces.insert(source)
            guard let row = try rows("SELECT payload FROM executions WHERE nonce=?", [source]).first else {
                throw CoreError("unresolved_write", "Recovery dependency evidence is missing")
            }
            let marker = try JSON.parse(Data(row[0].utf8))
            let retained = try secret(nonce: source, column: "payload_cipher")
            let ancestor = try singleStoredConflictScope(nonce: source, marker: marker)
            scope.groups.formUnion(ancestor.groups); scope.eventIDs.formUnion(ancestor.eventIDs); scope.nonces.formUnion(ancestor.nonces)
            scope.complete = scope.complete && ancestor.complete
            if ancestor.calendar != scope.calendar { scope.calendar = nil; scope.complete = false }
            for value in [retained?["before"]["id"] ?? .null, retained?["event_id"] ?? .null, retained?["series"]["selected"]["id"] ?? .null, marker["event_id"], retained?["future"]["first_anchor"]["id"] ?? .null, marker["future_anchor_id"], retained?["future"]["reference"]["id"] ?? .null, marker["future_reference_id"]] {
                if let id = value.string { scope.eventIDs.insert(id) }
            }
            var nextPath = path; nextPath.insert(source)
            let ancestors = try sourceIDs(marker["rollback_of"]) + sourceIDs(retained?["rollback"]["source_change_ids"] ?? .null)
            pending += Set(ancestors).map { ($0, nextPath) }
        }
        try addCurrentBindings(to: &scope)
        if payload["version"] == .int(4) {
            let ids = [payload["before"]["id"].string, payload["series"]["selected"]["id"].string].compactMap { $0 }
            let bindings = try ids.map { try resolve($0, kind: "event") }
            guard ids.count == 2, bindings[0].nativeID == bindings[1].nativeID,
                  bindings[0].calendarID == bindings[1].calendarID, bindings[0].calendarID == scope.calendar else {
                throw CoreError("invalid_preview", "Series anchor and reference must identify the same native group")
            }
        }
        if payload["version"] == .int(5) {
            let ids = [payload["before"]["id"].string, payload["future"]["first_anchor"]["id"].string].compactMap { $0 }
            let bindings = try ids.map { try resolve($0, kind: "event") }
            guard ids.count == 2, bindings[0].nativeID == bindings[1].nativeID,
                  bindings[0].calendarID == bindings[1].calendarID, bindings[0].calendarID == scope.calendar else {
                throw CoreError("invalid_preview", "Future boundary and first anchor must identify the same native group")
            }
            // A provider split can mint groups the immutable intent cannot know.
            // Retain this calendar-wide fallback permanently, including after expiry.
            scope.complete = false
        }
        if payload["version"] == .int(6) {
            let ids = [payload["before"]["id"].string, payload["future"]["first_anchor"]["id"].string, payload["future"]["reference"]["id"].string].compactMap { $0 }
            let bindings = try ids.map { try resolve($0, kind: "event") }
            guard ids.count == (payload["action"] == .string("delete") ? 3 : 2), let first = bindings.first,
                  bindings.allSatisfy({ $0.nativeID == first.nativeID && $0.calendarID == first.calendarID && $0.calendarID == scope.calendar }) else { throw CoreError("invalid_preview", "Future termination references must identify one original native group") }
            scope.complete = false
        }
        if scope.existingTarget && (scope.groups.isEmpty || scope.eventIDs.isEmpty) { scope.complete = false }
        return scope
    }
    /// Called before accounting, so an oversized immutable marker can never
    /// strand unreadable intent or consume quota. Historical markers are untouched.
    func conflictMarker(payload: JSON, nonce: String) throws -> JSON {
        let scope = try writeConflictScope(payload: payload, nonce: nonce)
        _ = try WriteConflictScope(json: scope.json)
        var marker = try payloadMarker(payload).object!
        marker["conflict_scope"] = scope.json
        let result = JSON.object(marker)
        guard try result.data().count <= 262_144 else { throw CoreError("unresolved_write", "Native conflict evidence exceeds its durable bound") }
        return result
    }
    private func provenDisjoint(_ candidate: WriteConflictScope, from boundary: WriteConflictScope) throws -> Bool {
        guard candidate.nonces.isDisjoint(with: boundary.nonces), candidate.eventIDs.isDisjoint(with: boundary.eventIDs),
              let calendar = candidate.calendar, let otherCalendar = boundary.calendar else { return false }
        if calendar != otherCalendar { return true }
        guard candidate.complete, boundary.complete, candidate.existingTarget, !candidate.eventIDs.isEmpty,
              candidate.groups.isDisjoint(with: boundary.groups) else { return false }
        for group in candidate.groups {
            let witnesses = try rows("SELECT id FROM identities WHERE kind='event' AND native_id=? AND calendar_id=? AND rowid<=?", [group.item, group.calendar, String(boundary.cutoff)])
            guard witnesses.contains(where: { !boundary.eventIDs.contains($0[0]) }) else { return false }
        }
        return true
    }
    public func assertNoUnresolvedConflict(payload: JSON) throws {
        let unresolved = try rows("SELECT nonce,payload FROM executions WHERE state IN ('intent_recorded','unknown')")
        guard !unresolved.isEmpty else { return }
        let candidate = try writeConflictScope(payload: payload)
        for row in unresolved {
            let boundary = try storedConflictScope(nonce: row[0], marker: JSON.parse(Data(row[1].utf8)))
            guard try provenDisjoint(candidate, from: boundary) else {
                throw CoreError("unresolved_write", "An earlier unresolved outcome may affect this event or recurring group. An uncertain future operation can hold the entire calendar. Do not retry the Calendar change. Use list_unresolved_changes and get_stored_change, or get_change_status with the original change ID, to inspect the recorded outcome. Obtain the user’s explicit applied/not_applied assessment and evidence before preflight_reconciliation, then submit its exact reviewed preview through commit_reconciliation under normal host write confirmation. This is journal-only user assessment, not provider verification; never approve or infer the assessment automatically. If these tools are missing, refresh the calendar plugin tool definitions.")
            }
        }
    }
    /// Recovery boundaries use the same conservative independence proof as fresh
    /// writes; missing legacy evidence never supplies same-calendar witnesses.
    func executionsProvenDisjoint(_ candidate: [String], from boundary: [String]) throws -> Bool {
        try provenDisjoint(storedConflictScope(nonce: candidate[0], marker: JSON.parse(Data(candidate[1].utf8))),
                           from: storedConflictScope(nonce: boundary[0], marker: JSON.parse(Data(boundary[1].utf8))))
    }
}
