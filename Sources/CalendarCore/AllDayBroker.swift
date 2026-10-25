import Foundation
import CryptoKit

extension Broker {
    static let allDayRecoveryLimitation = "Recovery restores the retained civil-date interval and supported fields. EventKit may return an exclusive-midnight or inclusive-last-second end representation; the original raw endpoint representation is not guaranteed."
    static var allDayRecovery: JSON { .object(["mode": .string("all_day_fields"), "limitations": .array([.string(allDayRecoveryLimitation)])]) }
    static var allDayDatesCapabilities: JSON { .object(["version": .int(1), "storage_version": .int(6), "preview_version": .int(7), "create": .bool(true), "modify": .bool(true), "scope": .string("nonrecurring_floating"), "date_fields": .array(["start_date", "end_date_exclusive"].map(JSON.string)), "end_semantics": .string("exclusive"), "inverse_field_recovery": .bool(true), "delete": .bool(false), "recurring_structural_changes": .bool(false), "commit_tools": .array(["commit_create", "commit_modify", "commit_rollback"].map(JSON.string))]) }
    func allDayZone() throws -> String {
        let name = try backend.allDayProjectionTimeZone()
        guard TimeZone(identifier: name) != nil else { throw CoreError("invalid_timezone", "Native all-day projection timezone is unavailable") }
        return name
    }
    func requireAllDayZone(_ name: String) throws {
        guard try allDayZone() == name else { throw CoreError("stale_timezone", "Native all-day projection timezone changed; request a fresh preview") }
    }
    func checkAllDayTarget(_ event: EventRecord) throws {
        guard !event.recurring, !event.detached, event.occurrence == nil, event.fields.allDay, event.fields.timeZone == nil,
              event.details["recurrence_rules"] == .null || event.details["recurrence_rules"] == .array([]) else { throw CoreError("unsupported_all_day", "Civil-date edits require one nonrecurring floating all-day event") }
    }
    func validateAllDayText(_ fields: EventFields, retained: Bool) throws {
        if retained {
            guard [fields.title, fields.location, fields.notes].allSatisfy({ $0.unicodeScalars.count <= 262_144 }) else { throw CoreError("invalid_fields", "Retained all-day text exceeds the native snapshot bound") }
        } else {
            guard !fields.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, fields.title.count <= 1000,
                  fields.location.count <= 2000, fields.notes.count <= 10_000 else { throw CoreError("invalid_fields", "Invalid all-day event text") }
        }
    }
    func allDayContract(before: JSON, interval: AllDayInterval) throws -> JSON {
        let prior: JSON
        if before == .null { prior = .null }
        else { prior = try AllDayInterval.observed(EventFields(json: before["fields"]), projectionTimeZone: interval.projectionTimeZone).json }
        return .object(["version": .int(1), "semantics": .string("floating_civil_dates"), "projection_time_zone": .string(interval.projectionTimeZone), "before": prior, "after": interval.json, "write_end": .string("inclusive_last_second"), "readback_ends": .array(["exclusive_midnight", "inclusive_last_second"].map(JSON.string))])
    }
    func allDayPreview(action: String, calendar: JSON, before: JSON, fields: EventFields, interval: AllDayInterval, rollback: JSON? = nil, expires: Date? = nil) throws -> JSON {
        let issued = now()
        var body: [String: JSON] = ["version": .int(7), "nonce": .string(UUID().uuidString), "issued_at": .string(iso(issued)), "expires_at": .string(iso(min(issued.addingTimeInterval(600), expires ?? issued.addingTimeInterval(600)))), "installation_id": .string(try requiredMetadata("installation_id")), "credential_generation": .string(try requiredMetadata("credential_generation")), "key_id": .string(try requiredMetadata("key_id")), "action": .string(action), "scope": .string("this"), "calendar": calendar, "before": before, "after": interval.materialized(fields).json, "all_day": try allDayContract(before: before, interval: interval), "recovery": action == "create" ? recoveryContract(action: action, before: before) : Self.allDayRecovery]
        if let rollback { body["rollback"] = rollback }
        let envelope = JSON.object(body)
        guard try envelope.data().count <= 262_144 else { throw CoreError("preview_too_large", "All-day review exceeds the native preview limit") }
        let tag = HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: try signingKey())
        return .object(["preview": .object(["envelope": envelope, "authentication_tag": .string(Data(tag).base64EncodedString())]), "safety": try state.writeSafety(action: action, now: issued)])
    }
    func preflightAllDay(_ arguments: JSON) throws -> JSON {
        let args = try Arguments(arguments, allowed: ["action", "scope", "calendar_id", "event_id", "fields"], required: ["action", "scope", "fields"])
        let action = try args.string("action")
        guard ["create", "modify"].contains(action), args.values["scope"] == .string("this") else { throw CoreError("unsupported_scope", "Civil-date changes support one nonrecurring event with scope this") }
        var patch = try Arguments(args.values["fields"]!, allowed: ["all_day_dates", "title", "notes", "location", "alerts", "start", "end", "time_zone", "all_day", "recurrence"]).values
        let zone = try allDayZone(), dates: JSON
        if let supplied = patch.removeValue(forKey: "all_day_dates") {
            guard Set(patch.keys).isDisjoint(with: ["start", "end", "time_zone", "all_day", "recurrence"]) else { throw CoreError("invalid_arguments", "all_day_dates cannot be mixed with timestamp, timezone, all-day or recurrence fields") }
            dates = supplied
        } else {
            guard action == "create", patch["all_day"] == .bool(true), patch["recurrence"] == nil else { throw CoreError("unsupported_all_day", "Use all_day_dates for floating all-day creation or date changes") }
            let legacy = try EventFields.merged(.object(patch), with: nil)
            let (start, end, namedZone) = try legacy.dates()
            guard let namedZone else { throw CoreError("unsupported_timezone", "Use all_day_dates for floating all-day creation") }
            dates = .object(["start_date": .string(try AllDayInterval.label(start, zone: namedZone)), "end_date_exclusive": .string(try AllDayInterval.label(end, zone: namedZone))])
            for key in ["start", "end", "time_zone", "all_day"] { patch.removeValue(forKey: key) }
        }
        let interval = try AllDayInterval(dates, projectionTimeZone: zone)
        let calendar: JSON, before: JSON
        var fields: EventFields
        if action == "create" {
            guard args.values["event_id"] == nil else { throw CoreError("invalid_arguments", "Create does not accept event_id") }
            let calendarID = try args.string("calendar_id")
            guard let pair = try calendars().first(where: { $0.1["id"] == .string(calendarID) }) else { throw CoreError("calendar_missing", "Unknown calendar") }
            calendar = pair.1; before = .null; try checkWritable(calendar)
            fields = EventFields(title: "", start: iso(interval.start), end: iso(interval.writeEnd), timeZone: nil, allDay: true, alerts: [])
        } else {
            guard args.values["calendar_id"] == nil else { throw CoreError("invalid_arguments", "Calendar moves are unsupported") }
            let current = try event(args.string("event_id")); try checkAllDayTarget(current)
            before = try view(current); calendar = before["calendar"]; try checkWritable(calendar, event: current)
            _ = try AllDayInterval.observed(current.fields, projectionTimeZone: zone)
            fields = current.fields
        }
        var values = fields.json.object!; values.merge(patch) { _, new in new }
        fields = interval.materialized(try EventFields(json: .object(values)))
        try validateAllDayText(fields, retained: false)
        if action == "modify" {
            if fields.location != before["fields"]["location"].string, before["details"]["structured_location"] != .null { throw CoreError("unsupported_location", "Changing a structured location is unsupported") }
            if fields.alerts != nil { try validateRestorableAlarms(recoveryDetails(before["details"])["alarms"]) }
            try requireAllDayChange(fields, interval: interval, before: before, restoredAlarms: nil)
        }
        try requireAllDayZone(zone)
        return try allDayPreview(action: action, calendar: calendar, before: before, fields: fields, interval: interval)
    }
    func requireAllDayChange(_ fields: EventFields, interval: AllDayInterval, before: JSON, restoredAlarms: JSON?) throws {
        let prior = try AllDayInterval.observed(EventFields(json: before["fields"]), projectionTimeZone: interval.projectionTimeZone)
        let sameText = ["title", "notes", "location"].allSatisfy { fields.json[$0] == before["fields"][$0] }
        let sameAlerts: Bool
        if let restoredAlarms { sameAlerts = EventSnapshot.alarmsEquivalent(restoredAlarms, recoveryDetails(before["details"])["alarms"]) }
        else { sameAlerts = try fields.alerts.map { try EventAlert.matches($0, raw: recoveryDetails(before["details"])["alarms"]) } ?? true }
        guard prior.json != interval.json || !sameText || !sameAlerts else { throw CoreError("no_change", "No civil dates or event fields changed") }
    }
    /// Validate the authenticated or retained v7 temporal contract without changing it.
    func validateAllDayEnvelope(_ envelope: JSON, rollback: Bool) throws -> (AllDayInterval, EventFields) {
        let action = envelope["action"].string
        guard envelope["version"] == .int(7), envelope["scope"] == .string("this"), ["create", "modify"].contains(action ?? ""), !rollback || action == "modify",
              (action == "create") == (envelope["before"] == .null), let zone = envelope["all_day"]["projection_time_zone"].string else { throw CoreError("invalid_preview", "Invalid all-day action or scope") }
        let interval = try AllDayInterval(envelope["all_day"]["after"], projectionTimeZone: zone)
        guard envelope["all_day"] == (try allDayContract(before: envelope["before"], interval: interval)),
              envelope["recovery"] == (action == "create" ? recoveryContract(action: "create", before: .null) : Self.allDayRecovery) else { throw CoreError("invalid_preview", "All-day temporal or recovery declaration is invalid") }
        let stable: Set<String> = ["title", "start", "end", "time_zone", "all_day", "location", "notes"]
        let expected = rollback ? stable : (envelope["after"].object?["alerts"] == nil ? stable : stable.union(["alerts"]))
        _ = try Arguments(envelope["after"], allowed: expected, required: expected)
        let fields = try EventFields(json: envelope["after"])
        guard envelope["after"] == fields.json, fields.json == interval.materialized(fields).json, action != "create" || fields.alerts != nil else { throw CoreError("invalid_preview", "All-day raw assignment differs from the signed civil dates") }
        try validateAllDayText(fields, retained: rollback)
        return (interval, fields)
    }
    func commitAllDay(_ arguments: JSON, action: String, rollback: Bool) throws -> JSON {
        let args = try Arguments(arguments, allowed: ["preview"], required: ["preview"])
        let preview = try Arguments(args.values["preview"]!, allowed: ["envelope", "authentication_tag"], required: ["envelope", "authentication_tag"])
        let envelope = preview.values["envelope"]!
        var keys: Set<String> = ["version", "nonce", "issued_at", "expires_at", "installation_id", "credential_generation", "key_id", "action", "scope", "calendar", "before", "after", "all_day", "recovery"]
        if rollback { keys.insert("rollback") }
        let e = try Arguments(envelope, allowed: keys, required: keys)
        guard try envelope.data().count <= 262_144, let tag = Data(base64Encoded: try preview.string("authentication_tag")), tag.count == 32,
              try e.string("installation_id") == requiredMetadata("installation_id"), try e.string("credential_generation") == requiredMetadata("credential_generation"), try e.string("key_id") == requiredMetadata("key_id"),
              HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: try envelope.data(), using: try signingKey()), try e.string("action") == action else { throw CoreError("invalid_preview", "All-day preview integrity or binding validation failed") }
        let nonce = try e.string("nonce"), operation = rollback ? "commit_rollback" : "commit_" + action
        guard UUID(uuidString: nonce) != nil else { throw CoreError("invalid_preview", "Invalid nonce") }
        if let prior = try state.execution(nonce) {
            guard try state.payloadMatches(nonce: nonce, payload: envelope) else { throw CoreError("nonce_conflict", "Nonce payload differs from recorded execution") }
            try state.recordCommitObservation(replayed: true, operation: operation, now: now()); return prior.result
        }
        let (interval, fields) = try validateAllDayEnvelope(envelope, rollback: rollback)
        try requireAllDayExpiry(envelope)
        try requireAllDayZone(interval.projectionTimeZone)
        try state.assertNoUnresolvedConflict(payload: envelope)
        if rollback { try validateAllDayRollback(envelope) }
        let calendarID = try Arguments(envelope["calendar"], allowed: ["id", "title", "source", "writable", "subscribed"], required: ["id", "title", "source", "writable", "subscribed"]).string("id")
        guard let pair = try calendars().first(where: { $0.1["id"] == .string(calendarID) }), pair.1 == envelope["calendar"] else { throw CoreError("stale_calendar", "Calendar changed; request a new preview") }
        let existing: EventRecord?
        if action == "modify" {
            guard let eventID = envelope["before"]["id"].string else { throw CoreError("invalid_preview", "Missing all-day event identity") }
            let current = try event(eventID)
            guard EventSnapshot.equivalent(try view(current), envelope["before"]) else { throw CoreError("stale_event", "All-day event changed; request a new preview") }
            try checkAllDayTarget(current); existing = current
            if current.details["structured_location"] != .null, fields.location != current.fields.location { throw CoreError("unsupported_location", "Changing a structured location is unsupported") }
            if fields.alerts != nil { try validateRestorableAlarms(recoveryDetails(current.details)["alarms"]) }
        } else { existing = nil }
        try checkWritable(pair.1, event: existing)
        let alarms = rollback ? envelope["rollback"]["alarm_restoration"] : nil
        if let alarms { try validateRestorableAlarms(alarms) }
        if action == "modify" { try requireAllDayChange(fields, interval: interval, before: envelope["before"], restoredAlarms: alarms) }
        // Provider reads may take time or change the default timezone; check both
        // again immediately before the durable claim, not only at request entry.
        try requireAllDayZone(interval.projectionTimeZone); try requireAllDayExpiry(envelope)
        let sequence = try state.claim(nonce: nonce, payload: envelope, now: now())
        let result: JSON
        var verificationStage: WriteFailureStage = .providerMutation
        do {
            let saved = try providerMutation { try backend.applyAllDay(calendarID: pair.0.nativeID, existing: existing, fields: fields, interval: interval, restoredAlarms: alarms) }
            verificationStage = .resultVerification
            let observed = try backend.get(nativeID: saved.nativeID, calendarID: saved.calendarNativeID, occurrence: saved.occurrence, knownStart: parseDate(saved.fields.start))
            try requireAllDayZone(interval.projectionTimeZone)
            try verifyAllDayResult(observed, existing: existing, fields: fields, interval: interval, calendarID: pair.0.nativeID, restoredAlarms: alarms)
            if let id = envelope["before"]["id"].string { try state.rebindEvent(id: id, to: observed) }
            var response: [String: JSON] = ["nonce": .string(nonce), "state": .string("applied"), "action": .string(action), "event": try view(observed), "audit_sequence": .int(sequence)]
            if rollback { response["rollback_of"] = envelope["rollback"]["source_change_ids"]; response["event_id"] = envelope["before"]["id"] }
            result = .object(response)
        } catch {
            return writeFailure(error, nonce: nonce, action: action, sequence: sequence, stage: verificationStage)
        }
        do { try state.finish(nonce: nonce, state: "applied", result: result, event: "write_applied"); return result }
        catch { return unknownWrite(error, nonce: nonce, action: action, sequence: sequence, stage: .outcomePersistence) }
    }
    func requireAllDayExpiry(_ envelope: JSON) throws {
        let current = now(), issued = try parseDate(envelope["issued_at"].string ?? ""), expiry = try parseDate(envelope["expires_at"].string ?? "")
        guard issued <= current.addingTimeInterval(30), expiry > current, expiry > issued, expiry.timeIntervalSince(issued) <= 600.001 else { throw CoreError("preview_expired", "All-day preview expired; request a new preflight") }
    }
    func verifyAllDayResult(_ observed: EventRecord, existing: EventRecord?, fields: EventFields, interval: AllDayInterval, calendarID: String, restoredAlarms: JSON?) throws {
        try checkAllDayTarget(observed)
        guard observed.calendarNativeID == calendarID, try interval.matches(observed.fields),
              observed.fields.title == fields.title, observed.fields.notes == fields.notes, observed.fields.location == fields.location else { throw CoreError("verification_failed", "Observed all-day dates or fields differ from the signed interval") }
        if let restoredAlarms { guard EventSnapshot.alarmsEquivalent(recoveryDetails(observed.details)["alarms"], restoredAlarms) else { throw CoreError("verification_failed", "Retained all-day alarms changed") } }
        else if let alerts = fields.alerts { guard try EventAlert.matches(alerts, raw: recoveryDetails(observed.details)["alarms"]) else { throw CoreError("verification_failed", "All-day alerts differ from the signed review") } }
        if let existing {
            guard observed.availability == existing.availability, observed.status == existing.status,
                  observed.hasAttendees == existing.hasAttendees, observed.hasOrganizer == existing.hasOrganizer else { throw CoreError("verification_failed", "Unrelated all-day state changed") }
            var keys = ["url", "structured_location", "attendees", "organizer", "recurrence_rules", "unsupported_external_alarm"]
            if fields.alerts == nil && restoredAlarms == nil { keys.append("alarms") }
            for key in keys {
                guard key == "alarms" ? EventSnapshot.alarmsEquivalent(observed.details[key], existing.details[key]) : observed.details[key] == existing.details[key] else { throw CoreError("verification_failed", "Unrelated all-day details changed") }
            }
        } else {
            // EventKit can wrap the assigned plain location without coordinates.
            // Match only its exact native snapshot shape; retain the raw observation.
            let location = observed.details["structured_location"]
            let plainLocation: JSON = .object(["title": .string(fields.location), "radius": .string("0.0")])
            guard !observed.hasAttendees, !observed.hasOrganizer, observed.status != "cancelled",
                  observed.details["url"] == .null, location == .null || location == plainLocation,
                  observed.details["unsupported_external_alarm"] != .bool(true) else { throw CoreError("verification_failed", "Unexpected all-day creation metadata") }
        }
    }
}
