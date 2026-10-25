import Foundation
import CryptoKit

struct FutureTerminationSelection {
    let selected: EventRecord
    let anchor: EventRecord
    let before: JSON
    let future: JSON
}

extension Broker {
    static let terminationLimitations = [
        "Stops the current provider pattern from the selected future occurrence, including that occurrence and later occurrences in the pattern. Earlier occurrence fields and times are outside the deletion; other split segments and independent copies are not included.",
        "The supplied cutoff is inclusive. The signed boundary is the first eligible occurrence found at or after that cutoff in the signed bounded selection window. It must still be in the future when removal begins. Excluded dates have no default occurrence to select.",
        "EventKit controls recurrence termination, detached overrides and exclusions. Detached or moved occurrences may survive, including ones before the selected default boundary or beyond the bounded query. Those require separate identified occurrence deletion; this operation does not prove that every event after the cutoff is removed.",
        "Recovery creates a separate recurring series from the original deleted boundary with new provider identities and the retained default fields and supported rule. The original earlier segment stays truncated; the new series is not reattached or merged with it.",
        "Recovery does not restore exclusions or detached overrides. Previously skipped occurrences can reappear, and surviving moved or detached events can be duplicated by new default occurrences. Other split segments and independent copies are neither restored nor removed.",
        "Recovery may recreate occurrences from the original deleted boundary that are already in the past when recovery is approved. It requires a separate exact preview and write confirmation, retained details, unchanged verified prefix state and no conflicting later intent.",
        "One future termination can remove an unbounded number of occurrences and consumes one delete intent under the installation-wide safety limits. Recovery is a new recurring-series creation under the normal creation policy."
    ]
    static var terminationRecovery: JSON { .object(["mode": .string("independent_tail_copy"), "limitations": .array(terminationLimitations.map(JSON.string))]) }
    static var futureTerminationCapabilities: JSON { .object(["version": .int(1), "storage_version": .int(5), "preview_version": .int(6), "future_delete": .bool(true), "cutoff_forms": .array(["date_with_time_zone", "offset_datetime"].map(JSON.string)), "max_selection_days": .int(366), "recurrence_ends": .array(["unbounded", "until"].map(JSON.string)), "recovery": .string("independent_tail_copy"), "past_occurrence_delete": .bool(false), "calendar_container_delete": .bool(false), "commit_tools": .array(["commit_future_delete", "commit_future_restore"].map(JSON.string))]) }

    func hasFutureTerminationRecoveryContract(_ payload: JSON) -> Bool {
        payload["version"] == .int(6) && payload["action"] == .string("delete") && payload["scope"] == .string("future") && payload["rollback"] == .null && payload["recovery"] == Self.terminationRecovery
    }
    func checkTailCopyRestorable(_ record: EventRecord) throws {
        _ = try FutureTerminationPattern.validateRetainedFields(record.fields)
        guard !record.fields.allDay else { throw CoreError("unsupported_restore", "All-day termination is unsupported because independent-copy recovery lacks a verified civil-date contract") }
        guard record.fields.timeZone != nil, ["free", "busy", "tentative", "unavailable", "unknown"].contains(record.availability) else { throw CoreError("unsupported_restore", "Tail copy needs a supported named timezone and availability") }
        let details = recoveryDetails(record.details)
        if details["url"] != .null { guard let value = details["url"].string, URL(string: value) != nil else { throw CoreError("unsupported_restore", "Invalid retained URL") } }
        try validateRestorableLocation(details["structured_location"]); try validateRestorableAlarms(details["alarms"])
    }
    func terminationSelection(referenceID: String, cutoff: JSON) throws -> FutureTerminationSelection {
        let resolved = try FutureCutoff(cutoff), reference = try event(referenceID), referenceView = try view(reference), anchor = try seriesAnchor(for: reference)
        let anchorView = try view(anchor, knownCalendar: referenceView["calendar"])
        try checkWritable(referenceView["calendar"], event: reference); try checkWritable(anchorView["calendar"], event: anchor)
        // This is the backend's complete bounded result, never public query_events' limited page.
        let records = try backend.query(start: resolved.start, end: resolved.end, calendarIDs: [reference.calendarNativeID])
        guard records.count <= 100_000 else { throw CoreError("future_selection_too_large", "The complete selection window exceeds the native resource bound; narrow the cutoff or reference") }
        let group = records.filter { $0.nativeID == reference.nativeID && $0.calendarNativeID == reference.calendarNativeID }
        let candidates = try group.filter { record in
            guard record.recurring, !record.detached, let occurrence = record.occurrence else { return false }
            let date = try parseDate(occurrence)
            guard date >= resolved.start, date < resolved.end else { return false }
            guard record.fields.start == occurrence, iso(date) == occurrence else { throw CoreError("ambiguous_occurrence", "A moved or noncanonical occurrence cannot establish the cutoff boundary") }
            return true
        }.sorted { $0.occurrence! < $1.occurrence! }
        let first = candidates.first
        let detachedBefore = try group.contains { record in
            guard record.detached else { return false }
            let actual = try parseDate(record.fields.start), original = try record.occurrence.map(parseDate)
            return [actual, original].compactMap { $0 }.contains { $0 >= resolved.start && $0 < (first.flatMap { try? parseDate($0.fields.start) } ?? resolved.end) }
        }
        guard !detachedBefore else { throw CoreError("unsupported_detached_boundary", "A known detached or moved occurrence precedes the default boundary; handle it through separately scoped occurrence deletion") }
        guard let selected = first else { throw CoreError("future_boundary_unavailable", "No eligible boundary was observed in the complete bounded window; narrow the cutoff or choose a new reference") }
        guard candidates.filter({ $0.occurrence == selected.occurrence }).count == 1 else { throw CoreError("identity_ambiguous", "The first future boundary is ambiguous") }
        let before = try view(selected, knownCalendar: referenceView["calendar"])
        for (left, right) in [(before, referenceView), (before, anchorView), (referenceView, anchorView)] where left["id"] == right["id"] {
            guard EventSnapshot.equivalent(left, right) else { throw CoreError("stale_event", "One opaque occurrence changed during boundary selection") }
        }
        try checkWritable(before["calendar"], event: selected); try checkTailCopyRestorable(selected)
        let copy = try FutureTerminationPattern.copyRecurrence(selected: selected, anchor: anchor, now: now())
        let future: JSON = .object(["provider_scope": .string("selected_occurrence_and_future"), "cutoff": resolved.json, "resolved_cutoff": .string(iso(resolved.start)), "boundary": .string(selected.occurrence!), "reference": referenceView, "first_anchor": anchorView, "selection_window": resolved.window, "removes_entire_current_pattern": .bool(anchor.occurrence == selected.occurrence), "copy_recurrence": copy.json])
        return FutureTerminationSelection(selected: selected, anchor: anchor, before: before, future: future)
    }
    func terminationPreview(action: String, calendar: JSON, before: JSON, after: JSON, future: JSON, rollback: JSON? = nil, expires: Date? = nil) throws -> JSON {
        let issued = now()
        var expiry = min(issued.addingTimeInterval(600), expires ?? issued.addingTimeInterval(600))
        if action == "delete" { expiry = min(expiry, try parseDate(future["boundary"].string!)) }
        guard expiry > issued else { throw CoreError("preview_expired", "The future boundary or retained review expired") }
        var values: [String: JSON] = ["version": .int(6), "nonce": .string(UUID().uuidString), "issued_at": .string(iso(issued)), "expires_at": .string(iso(expiry)), "installation_id": .string(try requiredMetadata("installation_id")), "credential_generation": .string(try requiredMetadata("credential_generation")), "key_id": .string(try requiredMetadata("key_id")), "action": .string(action), "scope": .string("future"), "calendar": calendar, "before": before, "after": after, "future": future, "recovery": Self.terminationRecovery]
        if let rollback { values["rollback"] = rollback }
        let envelope = JSON.object(values)
        guard try envelope.data().count <= 262_144 else { throw CoreError("preview_too_large", "Complete future termination review exceeds the native bound") }
        let tag = HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: try signingKey())
        return .object(["preview": .object(["envelope": envelope, "authentication_tag": .string(Data(tag).base64EncodedString())]), "safety": try state.writeSafety(action: action, now: issued), "commit_tool": .string(action == "delete" ? "commit_future_delete" : "commit_future_restore")])
    }
    func preflightTermination(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["action", "scope", "event_id", "cutoff"], required: ["action", "scope", "event_id", "cutoff"])
        guard a.values["action"] == .string("delete"), a.values["scope"] == .string("future") else { throw CoreError("unsupported_scope", "An exact future deletion cutoff is required") }
        let selection = try terminationSelection(referenceID: a.string("event_id"), cutoff: a.values["cutoff"]!)
        return try terminationPreview(action: "delete", calendar: selection.before["calendar"], before: selection.before, after: .null, future: selection.future)
    }
    func verifiedEarlierAnchor(_ past: EventRecord, original: EventRecord, boundary: EventRecord) throws {
        guard past.nativeID == original.nativeID, past.calendarNativeID == original.calendarNativeID, past.occurrence == original.occurrence,
              past.recurring, !past.detached, past.fields == original.fields, past.availability == original.availability,
              past.status == original.status, past.hasAttendees == original.hasAttendees, past.hasOrganizer == original.hasOrganizer,
              EventSnapshot.alarmsEquivalent(recoveryDetails(past.details)["alarms"], recoveryDetails(original.details)["alarms"]),
              try FuturePattern.validPrefixRule(past.details["recurrence_rules"], original: original.details["recurrence_rules"], anchor: parseDate(original.occurrence!), boundary: parseDate(boundary.occurrence!)) else { throw CoreError("verification_failed", "Earlier anchor fields or provider termination changed unexpectedly") }
        for key in ["url", "structured_location", "attendees", "organizer", "unsupported_external_alarm", "created", "external_id"] { guard past.details[key] == original.details[key] else { throw CoreError("verification_failed", "Earlier anchor properties changed") } }
    }
    func requireAbsent(_ record: EventRecord) throws {
        do {
            _ = try backend.get(nativeID: record.nativeID, calendarID: record.calendarNativeID, occurrence: record.occurrence, knownStart: parseDate(record.fields.start))
            throw CoreError("stale_rollback", "The original deleted boundary resolves again")
        } catch let error as CoreError where error.code == "event_missing" { }
    }
    func authenticateTermination(_ arguments: JSON, restore: Bool) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["preview"], required: ["preview"]), p = try Arguments(a.values["preview"]!, allowed: ["envelope", "authentication_tag"], required: ["envelope", "authentication_tag"])
        let envelope = p.values["envelope"]!
        var keys: Set<String> = ["version", "nonce", "issued_at", "expires_at", "installation_id", "credential_generation", "key_id", "action", "scope", "calendar", "before", "after", "future", "recovery"]
        if restore { keys.insert("rollback") }
        let e = try Arguments(envelope, allowed: keys, required: keys)
        guard envelope["version"] == .int(6), envelope["action"] == .string(restore ? "create" : "delete"), envelope["scope"] == .string("future"),
              try envelope.data().count <= 262_144, let tag = Data(base64Encoded: try p.string("authentication_tag")), tag.count == 32,
              try e.string("installation_id") == requiredMetadata("installation_id"), try e.string("credential_generation") == requiredMetadata("credential_generation"), try e.string("key_id") == requiredMetadata("key_id"),
              HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: try envelope.data(), using: try signingKey()), envelope["recovery"] == Self.terminationRecovery,
              UUID(uuidString: try e.string("nonce")) != nil else { throw CoreError("invalid_preview", "Future termination preview integrity, action or disclosure failed") }
        _ = try Arguments(envelope["future"], allowed: ["provider_scope", "cutoff", "resolved_cutoff", "boundary", "reference", "first_anchor", "selection_window", "removes_entire_current_pattern", "copy_recurrence"], required: ["provider_scope", "cutoff", "resolved_cutoff", "boundary", "reference", "first_anchor", "selection_window", "removes_entire_current_pattern", "copy_recurrence"])
        guard envelope["future"]["provider_scope"] == .string("selected_occurrence_and_future"), restore ? envelope["before"] == .null : envelope["after"] == .null else { throw CoreError("invalid_preview", "Invalid future termination form") }
        return envelope
    }
    func terminationFreshTime(_ envelope: JSON, restore: Bool) throws -> Date {
        guard let issuedText = envelope["issued_at"].string, let expiryText = envelope["expires_at"].string else { throw CoreError("invalid_preview", "Missing review timestamps") }
        let current = now(), issued = try parseDate(issuedText), expiry = try parseDate(expiryText)
        guard issued <= current.addingTimeInterval(30), expiry > current, expiry > issued, expiry.timeIntervalSince(issued) <= 600.001 else { throw CoreError("preview_expired", "The future review expired") }
        if !restore { guard let boundaryText = envelope["future"]["boundary"].string, expiry <= (try parseDate(boundaryText)), try parseDate(boundaryText) > current else { throw CoreError("preview_expired", "The selected boundary elapsed") } }
        return current
    }
    func commitTermination(_ arguments: JSON) throws -> JSON {
        let envelope = try authenticateTermination(arguments, restore: false), nonce = envelope["nonce"].string!
        if let prior = try state.execution(nonce) {
            guard try state.payloadMatches(nonce: nonce, payload: envelope) else { throw CoreError("nonce_conflict", "Nonce payload differs from recorded execution") }
            try state.recordCommitObservation(replayed: true, operation: "commit_future_delete", now: now()); return prior.result
        }
        guard envelope["before"]["fields"]["all_day"] != .bool(true) else { throw CoreError("unsupported_restore", "All-day future deletion lacks a verified independent-copy recovery contract") }
        _ = try terminationFreshTime(envelope, restore: false)
        try state.assertNoUnresolvedConflict(payload: envelope)
        guard let reference = envelope["future"]["reference"]["id"].string else { throw CoreError("invalid_preview", "Missing selected pattern reference") }
        let selection = try terminationSelection(referenceID: reference, cutoff: envelope["future"]["cutoff"])
        guard EventSnapshot.equivalent(selection.before, envelope["before"]), EventSnapshot.terminationReferenceEquivalent(selection.future, envelope["future"]), selection.before["calendar"] == envelope["calendar"] else { throw CoreError("stale_event", "The cutoff, first anchor, reference or selected boundary changed") }
        _ = try FuturePattern.boundary(selection.selected, now: now())
        let claimedAt = try terminationFreshTime(envelope, restore: false)
        let sequence = try state.claim(nonce: nonce, payload: envelope, now: claimedAt)
        let result: JSON
        do {
            let removed = try backend.removeFuture(selected: selection.selected, originalAnchor: selection.anchor, boundaryNow: now)
            try requireAbsent(selection.selected)
            if selection.selected.occurrence == selection.anchor.occurrence { guard removed.pastAnchor == nil else { throw CoreError("verification_failed", "Unexpected earlier anchor") }; try requireAbsent(selection.anchor) }
            else { guard let past = removed.pastAnchor else { throw CoreError("verification_failed", "Earlier anchor witness is unavailable") }; try verifiedEarlierAnchor(past, original: selection.anchor, boundary: selection.selected) }
            result = .object(["nonce": .string(nonce), "state": .string("applied"), "action": .string("delete"), "event": .null, "deleted_boundary": selection.before, "past_anchor": try removed.pastAnchor.map { try view($0, knownCalendar: envelope["calendar"]) } ?? .null, "boundary": envelope["future"]["boundary"], "cutoff": envelope["future"]["cutoff"], "audit_sequence": .int(sequence)])
        } catch {
            let unknown: JSON = .object(["nonce": .string(nonce), "state": .string("unknown"), "action": .string("delete"), "audit_sequence": .int(sequence), "message": .string("Future termination may have happened; do not retry. Inspect the original nonce and reconcile before related changes")])
            try? state.finish(nonce: nonce, state: "unknown", result: unknown, event: "write_unknown"); return unknown
        }
        do { try state.finish(nonce: nonce, state: "applied", result: result, event: "write_applied"); return result }
        catch { return .object(["nonce": .string(nonce), "state": .string("unknown"), "message": .string("Termination returned but durable outcome recording failed; inspect the original nonce")]) }
    }
}
