import Foundation
import CryptoKit

extension Broker {
    static let futureLimitations = [
        "Applies changed default fields to the selected future occurrence and later occurrences in its current provider pattern. Earlier occurrence fields and times are outside the requested change; earlier split segments are not merged.",
        "EventKit may split the pattern and change provider identities and recurrence end metadata. Detached overrides and exclusions remain provider-controlled. The operation does not enumerate or verify every occurrence or guarantee propagation to detached overrides.",
        "Recovery reapplies only retained prior default fields to the same verified future segment while its original boundary is still in the future. It does not merge split segments or reconstruct recurrence topology, detached overrides, exclusions or provider identities; recovery may become unavailable before retained details expire.",
        "One future operation can affect an unbounded number of occurrences and consumes one modify intent under the installation-wide safety limits."
    ]
    static var futureRecovery: JSON { .object(["mode": .string("future_default_fields"), "limitations": .array(futureLimitations.map(JSON.string))]) }
    static var futureModificationCapabilities: JSON { .object(["version": .int(1), "storage_version": .int(4), "preview_version": .int(5), "future_modify": .bool(true), "fields": .array(["title", "notes", "location", "alerts"].map(JSON.string)), "inverse_field_recovery": .bool(true), "boundary": .string("selected_occurrence_inclusive_strictly_future"), "recurrence_ends": .array(["unbounded", "until"].map(JSON.string)), "series_delete": .bool(false), "structural_changes": .bool(false), "commit_tools": .array(["commit_future_modify", "commit_future_rollback"].map(JSON.string))]) }

    func futurePreview(before: JSON, anchor: JSON, after: JSON, mask: [String], rollback: JSON? = nil, expires: Date? = nil) throws -> JSON {
        let issued = now(), boundary = try parseDate(before["occurrence"].string ?? "")
        guard boundary > issued else { throw CoreError("future_boundary_elapsed", "The selected occurrence must still start strictly in the future") }
        var body: [String: JSON] = ["version": .int(5), "nonce": .string(UUID().uuidString), "issued_at": .string(iso(issued)), "expires_at": .string(iso(min(issued.addingTimeInterval(600), boundary, expires ?? boundary))), "installation_id": .string(try requiredMetadata("installation_id")), "credential_generation": .string(try requiredMetadata("credential_generation")), "key_id": .string(try requiredMetadata("key_id")), "action": .string("modify"), "scope": .string("future"), "calendar": before["calendar"], "before": before, "after": after, "recovery": Self.futureRecovery, "future": .object(["provider_scope": .string("selected_occurrence_and_future"), "boundary": before["occurrence"], "first_anchor": anchor, "changed_fields": .array(mask.map(JSON.string))])]
        if let rollback { body["rollback"] = rollback }
        let envelope = JSON.object(body)
        guard try envelope.data().count <= 262_144 else { throw CoreError("preview_too_large", "Future review exceeds native preview limit") }
        let tag = HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: try signingKey())
        return .object(["preview": .object(["envelope": envelope, "authentication_tag": .string(Data(tag).base64EncodedString())]), "safety": try state.writeSafety(action: "modify", now: issued), "commit_tool": .string(rollback == nil ? "commit_future_modify" : "commit_future_rollback")])
    }
    func preflightFuture(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["action", "scope", "event_id", "fields"], required: ["action", "scope", "event_id", "fields"])
        guard a.values["action"] == .string("modify"), a.values["scope"] == .string("future") else { throw CoreError("unsupported_scope", "Only future default-field modification is supported") }
        let patch = try Arguments(a.values["fields"]!, allowed: Set(Self.seriesFields)), mask = patch.values.keys.sorted()
        let selected = try event(a.string("event_id")), before = try view(selected), anchor = try seriesAnchor(for: selected)
        _ = try FuturePattern.validate(selected: selected, anchor: anchor, now: now())
        let anchorView = try view(anchor, knownCalendar: before["calendar"])
        try checkWritable(before["calendar"], event: selected); try checkWritable(anchorView["calendar"], event: anchor)
        var values = selected.fields.json.object!; values.merge(patch.values) { _, new in new }
        let fields = try validateSeriesFields(.object(values), before: before, mask: mask, rollback: false)
        if mask.contains("location"), anchor.details["structured_location"] != .null,
           fields.location != anchor.fields.location { throw CoreError("unsupported_location", "Changing a structured anchor location is unsupported") }
        let sameAlerts = try fields.alerts.map { try EventAlert.matches($0, raw: recoveryDetails(selected.details)["alarms"]) } ?? true
        guard fields.withoutAlerts != selected.fields.withoutAlerts || !sameAlerts else { throw CoreError("no_change", "No future default fields changed") }
        if mask.contains("alerts") { try validateRestorableAlarms(recoveryDetails(selected.details)["alarms"]); try validateRestorableAlarms(recoveryDetails(anchor.details)["alarms"]) }
        return try futurePreview(before: before, anchor: anchorView, after: fields.json, mask: mask)
    }
    func verifyFutureResult(_ result: FutureWriteResult, selected: EventRecord, anchor: EventRecord, fields: EventFields, mask: [String], restoredAlarms: JSON?) throws {
        let written = result.boundary, first = try backend.firstSeriesOccurrence(for: written)
        guard written == first, written.occurrence == selected.occurrence,
              written.calendarNativeID == selected.calendarNativeID, written.recurring, !written.detached,
              written.fields.withoutAlerts == fields.withoutAlerts, written.details["recurrence_rules"] == selected.details["recurrence_rules"],
              written.availability == selected.availability, written.status == selected.status,
              written.hasAttendees == selected.hasAttendees, written.hasOrganizer == selected.hasOrganizer else { throw CoreError("verification_failed", "Saved future boundary or recurrence differs from the signed change") }
        for key in ["url", "structured_location", "attendees", "organizer", "unsupported_external_alarm"] { guard written.details[key] == selected.details[key] else { throw CoreError("verification_failed", "Unrelated future boundary properties changed") } }
        if mask.contains("alerts") {
            if let restoredAlarms { guard EventSnapshot.alarmsEquivalent(recoveryDetails(written.details)["alarms"], restoredAlarms) else { throw CoreError("verification_failed", "Future alarms differ from retained restoration") } }
            else { guard let alerts = fields.alerts, try EventAlert.matches(alerts, raw: recoveryDetails(written.details)["alarms"]) else { throw CoreError("verification_failed", "Future alerts differ from the preview") } }
        } else { guard EventSnapshot.alarmsEquivalent(recoveryDetails(written.details)["alarms"], recoveryDetails(selected.details)["alarms"]) else { throw CoreError("verification_failed", "Unmasked future alarms changed") } }
        if anchor.occurrence != selected.occurrence {
            guard let past = result.pastAnchor, past.nativeID == anchor.nativeID, written.nativeID != past.nativeID,
                  past.calendarNativeID == anchor.calendarNativeID, past.occurrence == anchor.occurrence,
                  past.recurring, !past.detached, past.fields == anchor.fields, past.availability == anchor.availability,
                  past.status == anchor.status, past.hasAttendees == anchor.hasAttendees, past.hasOrganizer == anchor.hasOrganizer,
                  EventSnapshot.alarmsEquivalent(recoveryDetails(past.details)["alarms"], recoveryDetails(anchor.details)["alarms"]),
                  try FuturePattern.validPrefixRule(past.details["recurrence_rules"], original: anchor.details["recurrence_rules"], anchor: parseDate(anchor.occurrence!), boundary: parseDate(selected.occurrence!)) else { throw CoreError("verification_failed", "Earlier anchor fields or provider split termination could not be verified") }
            for key in ["url", "structured_location", "attendees", "organizer", "unsupported_external_alarm", "created", "external_id"] { guard past.details[key] == anchor.details[key] else { throw CoreError("verification_failed", "Earlier anchor properties changed") } }
        } else { guard result.pastAnchor == nil else { throw CoreError("verification_failed", "Unexpected earlier anchor witness") } }
    }
    func commitFuture(_ arguments: JSON, rollback: Bool) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["preview"], required: ["preview"])
        let p = try Arguments(a.values["preview"]!, allowed: ["envelope", "authentication_tag"], required: ["envelope", "authentication_tag"]), envelope = p.values["envelope"]!
        var keys: Set<String> = ["version", "nonce", "issued_at", "expires_at", "installation_id", "credential_generation", "key_id", "action", "scope", "calendar", "before", "after", "future", "recovery"]
        if rollback { keys.insert("rollback") }
        let e = try Arguments(envelope, allowed: keys, required: keys)
        guard envelope["version"] == .int(5), envelope["action"] == .string("modify"), envelope["scope"] == .string("future"),
              try envelope.data().count <= 262_144, let tag = Data(base64Encoded: try p.string("authentication_tag")), tag.count == 32,
              try e.string("installation_id") == requiredMetadata("installation_id"), try e.string("credential_generation") == requiredMetadata("credential_generation"), try e.string("key_id") == requiredMetadata("key_id"),
              HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: try envelope.data(), using: try signingKey()), envelope["recovery"] == Self.futureRecovery else { throw CoreError("invalid_preview", "Future preview integrity, binding or disclosure failed") }
        let future = try Arguments(envelope["future"], allowed: ["provider_scope", "boundary", "first_anchor", "changed_fields"], required: ["provider_scope", "boundary", "first_anchor", "changed_fields"])
        guard future.values["provider_scope"] == .string("selected_occurrence_and_future"), let values = future.values["changed_fields"]?.array,
              values.allSatisfy({ $0.string != nil }), envelope["before"]["occurrence"] == future.values["boundary"],
              envelope["before"]["fields"]["start"] == future.values["boundary"], let boundaryText = future.values["boundary"]?.string else { throw CoreError("invalid_preview", "Invalid exact future boundary") }
        let boundary = try parseDate(boundaryText)
        guard iso(boundary) == boundaryText else { throw CoreError("invalid_preview", "Future boundary must use canonical UTC") }
        let mask = values.compactMap(\.string), fields = try validateSeriesFields(envelope["after"], before: envelope["before"], mask: mask, rollback: rollback)
        guard fields.json == envelope["after"] else { throw CoreError("invalid_preview", "Future fields must use native canonical form") }
        let nonce = try e.string("nonce"), operation = rollback ? "commit_future_rollback" : "commit_future_modify"
        guard UUID(uuidString: nonce) != nil else { throw CoreError("invalid_preview", "Invalid nonce") }
        if let prior = try state.execution(nonce) {
            guard try state.payloadMatches(nonce: nonce, payload: envelope) else { throw CoreError("nonce_conflict", "Nonce payload differs from recorded execution") }
            try state.recordCommitObservation(replayed: true, operation: operation, now: now()); return prior.result
        }
        let current = now(), issued = try parseDate(e.string("issued_at")), expiry = try parseDate(e.string("expires_at"))
        guard issued <= current.addingTimeInterval(30), expiry > current, expiry > issued, expiry.timeIntervalSince(issued) <= 600.001,
              expiry <= boundary, boundary > current else { throw CoreError("preview_expired", "Future preview expired or its selected boundary elapsed; request a new preflight") }
        try state.assertNoUnresolvedConflict(payload: envelope)
        if rollback { try validateFutureRollback(envelope) }
        guard let id = envelope["before"]["id"].string else { throw CoreError("invalid_preview", "Missing future boundary identity") }
        let selected = try event(id), before = try view(selected), anchor = try seriesAnchor(for: selected), anchorView = try view(anchor, knownCalendar: before["calendar"])
        guard EventSnapshot.equivalent(before, envelope["before"]), EventSnapshot.equivalent(anchorView, envelope["future"]["first_anchor"]), before["calendar"] == envelope["calendar"] else { throw CoreError("stale_event", "Selected future boundary, first anchor or calendar changed") }
        _ = try FuturePattern.validate(selected: selected, anchor: anchor, now: now())
        try checkWritable(before["calendar"], event: selected); try checkWritable(anchorView["calendar"], event: anchor)
        if mask.contains("location"), anchor.details["structured_location"] != .null,
           fields.location != anchor.fields.location { throw CoreError("unsupported_location", "Changing a structured anchor location is unsupported") }
        if mask.contains("alerts") { try validateRestorableAlarms(recoveryDetails(selected.details)["alarms"]); try validateRestorableAlarms(recoveryDetails(anchor.details)["alarms"]) }
        if !rollback {
            let sameAlerts = try fields.alerts.map { try EventAlert.matches($0, raw: recoveryDetails(selected.details)["alarms"]) } ?? true
            guard fields.withoutAlerts != selected.fields.withoutAlerts || !sameAlerts else { throw CoreError("no_change", "No future default fields changed") }
        }
        let alarms = rollback && mask.contains("alerts") ? envelope["rollback"]["alarm_restoration"] : nil
        if let alarms { try validateRestorableAlarms(alarms) }
        // A boundary crossing before claim is rejected without charging an intent.
        _ = try FuturePattern.boundary(selected, now: now())
        let sequence = try state.claim(nonce: nonce, payload: envelope, now: current)
        let result: JSON
        do {
            let saved = try backend.applyFutureFields(selected: selected, originalAnchor: anchor, fields: fields, changedFields: mask, restoredAlarms: alarms, boundaryNow: now)
            try verifyFutureResult(saved, selected: selected, anchor: anchor, fields: fields, mask: mask, restoredAlarms: alarms)
            try state.rebindEvent(id: id, to: saved.boundary)
            var response: [String: JSON] = ["nonce": .string(nonce), "state": .string("applied"), "action": .string("modify"), "event": try view(saved.boundary), "audit_sequence": .int(sequence)]
            if let past = saved.pastAnchor { response["past_anchor"] = try view(past, knownCalendar: before["calendar"]) }
            if rollback { response["rollback_of"] = envelope["rollback"]["source_change_ids"]; response["event_id"] = before["id"] }
            result = .object(response)
        } catch {
            let unknown: JSON = .object(["nonce": .string(nonce), "state": .string("unknown"), "action": .string("modify"), "audit_sequence": .int(sequence), "message": .string("Future write may have happened; do not retry. Inspect the original nonce and reconcile before related changes")])
            try? state.finish(nonce: nonce, state: "unknown", result: unknown, event: "write_unknown"); return unknown
        }
        do { try state.finish(nonce: nonce, state: "applied", result: result, event: "write_applied"); return result }
        catch { return .object(["nonce": .string(nonce), "state": .string("unknown"), "message": .string("Future provider returned but durable outcome recording failed; inspect original nonce status")]) }
    }
}
