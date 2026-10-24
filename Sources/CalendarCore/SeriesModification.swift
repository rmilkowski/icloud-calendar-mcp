import Foundation
import CryptoKit

extension Broker {
    static let seriesFields = ["alerts", "location", "notes", "title"]
    static let seriesLimitations = [
        "Applies changed default fields to the provider's current recurring pattern from its first occurrence, including past and future occurrences in that pattern. Separate series segments are not merged.",
        "Detached occurrence overrides and exclusions are controlled by the provider. This operation does not verify every occurrence or guarantee that every detached override receives the same values.",
        "Recovery reapplies only the retained prior default fields to the same current pattern. It does not reconstruct detached overrides, exclusions, prior series structure, provider identities or earlier split segments.",
        "One series operation can affect an unbounded number of occurrences and consumes one modify intent under the installation-wide safety limits."
    ]
    static var seriesRecovery: JSON { .object(["mode": .string("series_default_fields"), "limitations": .array(seriesLimitations.map(JSON.string))]) }
    static var seriesModificationCapabilities: JSON { .object(["version": .int(1), "storage_version": .int(3), "preview_version": .int(4), "current_series_modify": .bool(true), "fields": .array(["title", "notes", "location", "alerts"].map(JSON.string)), "inverse_field_recovery": .bool(true), "future_scope": .bool(false), "series_delete": .bool(false), "structural_changes": .bool(false), "commit_tools": .array(["commit_series_modify", "commit_series_rollback"].map(JSON.string))]) }

    func seriesAnchor(for selected: EventRecord) throws -> EventRecord {
        guard selected.recurring, !selected.detached, let selectedDate = selected.occurrence else { throw CoreError("unsupported_scope", "Select a non-detached recurring occurrence") }
        let anchor = try backend.firstSeriesOccurrence(for: selected)
        guard anchor.recurring, !anchor.detached, let occurrence = anchor.occurrence,
              try parseDate(occurrence) <= parseDate(selectedDate),
              anchor.nativeID == selected.nativeID, anchor.calendarNativeID == selected.calendarNativeID,
              anchor.details["recurrence_rules"] == selected.details["recurrence_rules"] else { throw CoreError("ambiguous_occurrence", "Current series first-occurrence provenance is unavailable") }
        return anchor
    }
    func validateSeriesFields(_ after: JSON, before: JSON, mask: [String], rollback: Bool) throws -> EventFields {
        guard !mask.isEmpty, mask == Array(Set(mask)).sorted(), mask.allSatisfy(Self.seriesFields.contains) else { throw CoreError("invalid_preview", "Invalid exact series field mask") }
        let base: Set<String> = ["title", "start", "end", "time_zone", "all_day", "location", "notes"]
        let expected = !rollback && mask.contains("alerts") ? base.union(["alerts"]) : base
        _ = try Arguments(after, allowed: expected, required: expected)
        let fields = try EventFields(json: after)
        for key in ["start", "end", "time_zone", "all_day"] { guard after[key] == before["fields"][key] else { throw CoreError("invalid_preview", "Series structural fields cannot change") } }
        for key in ["title", "notes", "location"] {
            guard let text = after[key].string, text.unicodeScalars.count <= 262_144 else { throw CoreError("invalid_fields", "Series snapshot text exceeds the native bound") }
            if !mask.contains(key) { guard after[key] == before["fields"][key] else { throw CoreError("invalid_preview", "Unmasked series fields cannot change") } }
            else if !rollback {
                let limit = key == "title" ? 1000 : (key == "notes" ? 10_000 : 2000)
                guard text.count <= limit, key != "title" || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError("invalid_fields", "Invalid edited series text") }
            }
        }
        if mask.contains("location"), before["details"]["structured_location"] != .null,
           after["location"] != before["fields"]["location"] { throw CoreError("unsupported_location", "Changing a structured location is unsupported") }
        return fields
    }
    func seriesPreview(before: JSON, after: JSON, selected: JSON, mask: [String], rollback: JSON? = nil, expires: Date? = nil) throws -> JSON {
        let issued = now()
        var body: [String: JSON] = ["version": .int(4), "nonce": .string(UUID().uuidString), "issued_at": .string(iso(issued)), "expires_at": .string(iso(min(issued.addingTimeInterval(600), expires ?? issued.addingTimeInterval(600)))), "installation_id": .string(try requiredMetadata("installation_id")), "credential_generation": .string(try requiredMetadata("credential_generation")), "key_id": .string(try requiredMetadata("key_id")), "action": .string("modify"), "scope": .string("series"), "calendar": before["calendar"], "before": before, "after": after, "recovery": Self.seriesRecovery, "series": .object(["provider_scope": .string("current_pattern_from_first_occurrence"), "selected": selected, "changed_fields": .array(mask.map(JSON.string))])]
        if let rollback { body["rollback"] = rollback }
        let envelope = JSON.object(body)
        guard try envelope.data().count <= 262_144 else { throw CoreError("preview_too_large", "Series review exceeds native preview limit") }
        let tag = HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: try signingKey())
        return .object(["preview": .object(["envelope": envelope, "authentication_tag": .string(Data(tag).base64EncodedString())]), "safety": try state.writeSafety(action: "modify", now: issued), "commit_tool": .string(rollback == nil ? "commit_series_modify" : "commit_series_rollback")])
    }
    func preflightSeries(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["action", "scope", "event_id", "fields"], required: ["action", "scope", "event_id", "fields"])
        guard a.values["action"] == .string("modify"), a.values["scope"] == .string("series") else { throw CoreError("unsupported_scope", "Only nonstructural series modification is supported") }
        let patch = try Arguments(a.values["fields"]!, allowed: Set(Self.seriesFields))
        let mask = patch.values.keys.sorted()
        let selected = try event(a.string("event_id")), selectedView = try view(selected)
        try checkWritable(selectedView["calendar"], event: selected)
        let anchor = try seriesAnchor(for: selected), before = try view(anchor, knownCalendar: selectedView["calendar"])
        try checkWritable(before["calendar"], event: anchor)
        var values = anchor.fields.json.object!; values.merge(patch.values) { _, new in new }
        let after = JSON.object(values), fields = try validateSeriesFields(after, before: before, mask: mask, rollback: false)
        let sameAlerts = try fields.alerts.map { try EventAlert.matches($0, raw: recoveryDetails(anchor.details)["alarms"]) } ?? true
        guard fields.withoutAlerts != anchor.fields.withoutAlerts || !sameAlerts else { throw CoreError("no_change", "No series default fields changed") }
        if mask.contains("alerts") { try validateRestorableAlarms(recoveryDetails(anchor.details)["alarms"]) }
        return try seriesPreview(before: before, after: fields.json, selected: selectedView, mask: mask)
    }
    func verifySeriesResult(_ written: EventRecord, anchor: EventRecord, fields: EventFields, mask: [String], restoredAlarms: JSON?) throws {
        guard written.calendarNativeID == anchor.calendarNativeID, written.occurrence == anchor.occurrence,
              written.recurring, !written.detached, written.fields.withoutAlerts == fields.withoutAlerts,
              written.details["recurrence_rules"] == anchor.details["recurrence_rules"],
              written.availability == anchor.availability, written.status == anchor.status else { throw CoreError("verification_failed", "Written series defaults or anchor structure differ from the signed preview") }
        for key in ["url", "structured_location", "attendees", "organizer"] { guard written.details[key] == anchor.details[key] else { throw CoreError("verification_failed", "Unrelated series properties changed") } }
        if mask.contains("alerts") {
            if let restoredAlarms { guard EventSnapshot.alarmsEquivalent(recoveryDetails(written.details)["alarms"], restoredAlarms) else { throw CoreError("verification_failed", "Series alarms differ from retained restoration") } }
            else { guard let alerts = fields.alerts, try EventAlert.matches(alerts, raw: recoveryDetails(written.details)["alarms"]) else { throw CoreError("verification_failed", "Series alerts differ from preview") } }
        } else { guard EventSnapshot.alarmsEquivalent(recoveryDetails(written.details)["alarms"], recoveryDetails(anchor.details)["alarms"]) else { throw CoreError("verification_failed", "Unmasked series alarms changed") } }
    }
    func commitSeries(_ arguments: JSON, rollback: Bool) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["preview"], required: ["preview"])
        let p = try Arguments(a.values["preview"]!, allowed: ["envelope", "authentication_tag"], required: ["envelope", "authentication_tag"]), envelope = p.values["envelope"]!
        var keys: Set<String> = ["version", "nonce", "issued_at", "expires_at", "installation_id", "credential_generation", "key_id", "action", "scope", "calendar", "before", "after", "series", "recovery"]
        if rollback { keys.insert("rollback") }
        let e = try Arguments(envelope, allowed: keys, required: keys)
        guard envelope["version"] == .int(4), envelope["action"] == .string("modify"), envelope["scope"] == .string("series"),
              try envelope.data().count <= 262_144, let tag = Data(base64Encoded: try p.string("authentication_tag")), tag.count == 32,
              try e.string("installation_id") == requiredMetadata("installation_id"), try e.string("credential_generation") == requiredMetadata("credential_generation"), try e.string("key_id") == requiredMetadata("key_id"),
              HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: try envelope.data(), using: try signingKey()), envelope["recovery"] == Self.seriesRecovery else { throw CoreError("invalid_preview", "Series preview integrity, binding or disclosure failed") }
        let series = try Arguments(envelope["series"], allowed: ["provider_scope", "selected", "changed_fields"], required: ["provider_scope", "selected", "changed_fields"])
        guard series.values["provider_scope"] == .string("current_pattern_from_first_occurrence"), let values = series.values["changed_fields"]?.array, values.allSatisfy({ $0.string != nil }) else { throw CoreError("invalid_preview", "Invalid series reference") }
        let mask = values.compactMap(\.string), fields = try validateSeriesFields(envelope["after"], before: envelope["before"], mask: mask, rollback: rollback)
        guard envelope["after"] == fields.json else { throw CoreError("invalid_preview", "Series field directives must use native canonical form") }
        let nonce = try e.string("nonce"), operation = rollback ? "commit_series_rollback" : "commit_series_modify"
        guard UUID(uuidString: nonce) != nil else { throw CoreError("invalid_preview", "Invalid nonce") }
        if let prior = try state.execution(nonce) {
            guard try state.payloadMatches(nonce: nonce, payload: envelope) else { throw CoreError("nonce_conflict", "Nonce payload differs from recorded execution") }
            try state.recordCommitObservation(replayed: true, operation: operation, now: now()); return prior.result
        }
        let current = now(), issued = try parseDate(e.string("issued_at")), expiry = try parseDate(e.string("expires_at"))
        guard issued <= current.addingTimeInterval(30), expiry > current, expiry > issued, expiry.timeIntervalSince(issued) <= 600.001 else { throw CoreError("preview_expired", "Series preview expired; request a new preflight") }
        guard try !state.hasUnresolved() else { throw CoreError("unresolved_write", "Resolve earlier unknown outcomes before any fresh write") }
        if rollback { try validateSeriesRollback(envelope) }
        guard let selectedID = envelope["series"]["selected"]["id"].string else { throw CoreError("invalid_preview", "Missing selected series reference") }
        let selected = try event(selectedID), selectedView = try view(selected)
        guard EventSnapshot.equivalent(selectedView, envelope["series"]["selected"]) else { throw CoreError("stale_event", "Selected series occurrence changed") }
        let anchor = try seriesAnchor(for: selected), before = try view(anchor, knownCalendar: selectedView["calendar"])
        guard EventSnapshot.equivalent(before, envelope["before"]), before["calendar"] == envelope["calendar"] else { throw CoreError("stale_event", "Series first anchor or calendar changed") }
        try checkWritable(before["calendar"], event: selected); try checkWritable(before["calendar"], event: anchor)
        if mask.contains("alerts") { try validateRestorableAlarms(recoveryDetails(anchor.details)["alarms"]) }
        if !rollback {
            let sameAlerts = try fields.alerts.map { try EventAlert.matches($0, raw: recoveryDetails(anchor.details)["alarms"]) } ?? true
            guard fields.withoutAlerts != anchor.fields.withoutAlerts || !sameAlerts else { throw CoreError("no_change", "No series default fields changed") }
        }
        let alarms = rollback && mask.contains("alerts") ? envelope["rollback"]["alarm_restoration"] : nil
        if let alarms { try validateRestorableAlarms(alarms) }
        let sequence = try state.claim(nonce: nonce, payload: envelope, now: current)
        let result: JSON
        do {
            let saved = try backend.applySeriesFields(anchor: anchor, fields: fields, changedFields: mask, restoredAlarms: alarms)
            let verified = try backend.firstSeriesOccurrence(for: saved)
            try verifySeriesResult(verified, anchor: anchor, fields: fields, mask: mask, restoredAlarms: alarms)
            try state.rebindEvent(id: before["id"].string!, to: verified)
            var response: [String: JSON] = ["nonce": .string(nonce), "state": .string("applied"), "action": .string("modify"), "event": try view(verified), "audit_sequence": .int(sequence)]
            if rollback { response["rollback_of"] = envelope["rollback"]["source_change_ids"]; response["event_id"] = before["id"] }
            result = .object(response)
        } catch {
            let unknown: JSON = .object(["nonce": .string(nonce), "state": .string("unknown"), "action": .string("modify"), "audit_sequence": .int(sequence), "message": .string("Series write may have happened; do not retry or create another change until reconciled")])
            try? state.finish(nonce: nonce, state: "unknown", result: unknown, event: "write_unknown"); return unknown
        }
        do { try state.finish(nonce: nonce, state: "applied", result: result, event: "write_applied"); return result }
        catch { return .object(["nonce": .string(nonce), "state": .string("unknown"), "message": .string("Series provider returned but durable outcome recording failed; inspect original nonce status")]) }
    }
}
