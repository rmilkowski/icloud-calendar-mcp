// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit

/// Every protocol request and EventKit operation runs under this single broker lock.
/// The state directory lock additionally excludes a second resident process.
public final class Broker: @unchecked Sendable {
    public let state: StateStore
    let backend: any CalendarBackend
    let now: () -> Date
    let lock = NSLock()
    private var localRecoveryUIAvailable = false
    public init(state: StateStore, backend: any CalendarBackend, now: @escaping () -> Date = Date.init) {
        self.state = state; self.backend = backend; self.now = now
    }
    public func setLocalRecoveryUIAvailable(_ available: Bool) {
        lock.lock(); defer { lock.unlock() }
        localRecoveryUIAvailable = available
    }
    public func handle(_ request: JSON) -> JSON {
        lock.lock(); defer { lock.unlock() }
        do {
            let r = try Arguments(request, allowed: ["op", "arguments"], required: ["op", "arguments"])
            try state.expireRecoveryDetails(now: now())
            return .object(["result": try perform(try r.string("op"), arguments: r.values["arguments"]!)])
        } catch {
            var failure = error as? CoreError ?? CoreError("native_error", "Native operation failed safely")
            if request["op"].string?.hasPrefix("commit_") == true {
                do { try state.recordCommitObservation(replayed: false, operation: request["op"].string ?? "", code: failure.code, now: now()) }
                catch { failure = CoreError("audit_unavailable", "Cannot durably audit rejected commit; no new write allowed") }
            }
            return .object(["error": .object(["code": .string(failure.code), "message": .string(failure.message)])])
        }
    }
    func calendars() throws -> [(CalendarRecord, JSON)] {
        try backend.calendars().map { record in
            let id = try state.identity(kind: "calendar", nativeID: record.nativeID)
            return (record, record.view(id: id))
        }.sorted { ($0.1["id"].string ?? "") < ($1.1["id"].string ?? "") }
    }
    func view(_ record: EventRecord, knownCalendar: JSON? = nil) throws -> JSON {
        guard let calendar = try knownCalendar ?? calendars().first(where: { $0.0.nativeID == record.calendarNativeID })?.1 else { throw CoreError("calendar_missing", "Event calendar is unavailable") }
        let id = try state.identity(kind: "event", nativeID: record.nativeID, calendarID: record.calendarNativeID, occurrence: record.occurrence, knownStart: record.fields.start)
        return try record.view(id: id, calendar: calendar)
    }
    func event(_ id: String) throws -> EventRecord {
        let ref = try state.resolve(id, kind: "event")
        return try backend.get(nativeID: ref.nativeID, calendarID: ref.calendarID, occurrence: ref.occurrence, knownStart: parseDate(ref.knownStart))
    }
    private func perform(_ op: String, arguments: JSON) throws -> JSON {
        switch op {
        case "reconciliation_capabilities":
            _ = try Arguments(arguments, allowed: [])
            return Self.reconciliationCapabilities
        case "list_unresolved_changes": return try listUnresolvedChanges(arguments)
        case "preflight_reconciliation": return try preflightReconciliation(arguments)
        case "commit_reconciliation": return try commitReconciliation(arguments)
        case "all_day_dates_capabilities":
            _ = try Arguments(arguments, allowed: [])
            return Self.allDayDatesCapabilities
        case "future_termination_capabilities":
            _ = try Arguments(arguments, allowed: [])
            return Self.futureTerminationCapabilities
        case "commit_future_delete": return try commitTermination(arguments)
        case "commit_future_restore": return try commitFutureRestore(arguments)
        case "future_modification_capabilities":
            _ = try Arguments(arguments, allowed: [])
            return Self.futureModificationCapabilities
        case "commit_future_modify": return try commitFuture(arguments, rollback: false)
        case "commit_future_rollback": return try commitFuture(arguments, rollback: true)
        case "series_modification_capabilities":
            _ = try Arguments(arguments, allowed: [])
            return Self.seriesModificationCapabilities
        case "commit_series_modify": return try commitSeries(arguments, rollback: false)
        case "commit_series_rollback": return try commitSeries(arguments, rollback: true)
        case "recurrence_capabilities":
            _ = try Arguments(arguments, allowed: [])
            return .object(["version": .int(1), "recurrence": .bool(true), "preview_version": .int(3), "create_series": .bool(true), "modify_occurrence": .bool(true), "delete_occurrence": .bool(true), "future_scope": .bool(false), "series_modify_delete": .bool(false), "delete_recovery": .string("standalone_copy"), "max_count": .int(1000)])
        case "alerts_capabilities":
            _ = try Arguments(arguments, allowed: [])
            return .object(["version": .int(1), "alerts": .bool(true), "max_alerts": .int(10), "preview_version": .int(2)])
        case "commit_observation_status":
            _ = try Arguments(arguments, allowed: [])
            return try state.commitObservationStatus()
        case "recovery_capabilities":
            _ = try Arguments(arguments, allowed: [])
            return .object(["version": .int(1), "storage_version": .int(7), "recovery": .bool(true), "detail_retention": .bool(true), "local_ui": .bool(localRecoveryUIAvailable), "max_selection": .int(25)])
        case "list_changes": return try listChanges(arguments)
        case "get_stored_change": return try storedChange(arguments)
        case "preflight_rollback": return try preflightRollback(arguments)
        case "commit_rollback":
            guard let action = arguments["preview"]["envelope"]["action"].string, ["create", "modify"].contains(action) else { throw CoreError("invalid_preview", "Invalid rollback action") }
            return try commit(arguments, action: action, rollback: true)
        case "list_calendars":
            _ = try Arguments(arguments, allowed: [])
            return .object(["calendars": .array(try calendars().map(\.1))])
        case "get_event":
            let a = try Arguments(arguments, allowed: ["event_id"], required: ["event_id"])
            return .object(["event": try view(event(a.string("event_id")))])
        case "query_events", "get_availability": return try query(arguments, availability: op == "get_availability")
        case "preflight_change": return try preflight(arguments)
        case "commit_create", "commit_modify", "commit_delete": return try commit(arguments, action: String(op.dropFirst(7)))
        case "get_change_status":
            let a = try Arguments(arguments, allowed: ["nonce"], required: ["nonce"])
            guard let parsedNonce = UUID(uuidString: try a.string("nonce")) else { throw CoreError("invalid_arguments", "Invalid nonce") }; let nonce = parsedNonce.uuidString
            guard let execution = try state.execution(nonce) else { return .object(["nonce": .string(nonce), "state": .string("not_received")]) }
            return execution.result
        default: throw CoreError("unknown_operation", "Unsupported native operation")
        }
    }
    private func query(_ arguments: JSON, availability: Bool) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["start", "end", "calendar_ids", "time_zone"], required: ["start", "end"])
        let start = try parseDate(a.string("start")), end = try parseDate(a.string("end"))
        guard end > start, end.timeIntervalSince(start) <= 93 * 86_400 else { throw CoreError("invalid_range", "Query must span at most 93 days") }
        let zone = a.values["time_zone"]?.string ?? "Europe/London"
        guard TimeZone(identifier: zone) != nil, a.values["time_zone"] == nil || a.values["time_zone"]?.string != nil else { throw CoreError("invalid_timezone", "Invalid display timezone") }
        var selected = try calendars()
        if let filter = a.values["calendar_ids"] {
            guard let array = filter.array, array.count <= 100, array.allSatisfy({ $0.string != nil }), Set(array.compactMap(\.string)).count == array.count else { throw CoreError("invalid_arguments", "Invalid calendar IDs") }
            let ids = Set(array.compactMap(\.string)); selected = selected.filter { ids.contains($0.1["id"].string ?? "") }
            guard selected.count == ids.count else { throw CoreError("calendar_missing", "Unknown calendar identity") }
        }
        let events = try selected.isEmpty ? [] : backend.query(start: start, end: end, calendarIDs: selected.map { $0.0.nativeID })
        guard events.count <= 1000 else { throw CoreError("too_many_events", "Narrow the range to at most 1000 events") }
        let calendarMap = Dictionary(uniqueKeysWithValues: selected.map { ($0.0.nativeID, $0.1) })
        let views = try events.map { try view($0, knownCalendar: calendarMap[$0.calendarNativeID]) }.sorted { ($0["fields"]["start"].string ?? "", $0["id"].string ?? "") < ($1["fields"]["start"].string ?? "", $1["id"].string ?? "") }
        var result: [String: JSON] = ["start": .string(iso(start)), "end": .string(iso(end)), "time_zone": .string(zone), "calendar_ids": .array(selected.map { $0.1["id"] }), "snapshot_at": .string(iso(now()))]
        if !availability { result["events"] = .array(views); return .object(result) }
        var blocks: [(Date, Date, [JSON])] = []
        for value in views where value["status"].string != "cancelled" && value["availability"].string != "free" {
            blocks.append((max(start, try parseDate(value["fields"]["start"].string!)), min(end, try parseDate(value["fields"]["end"].string!)), [value["id"]]))
        }
        blocks.sort { $0.0 < $1.0 }; var merged: [(Date, Date, [JSON])] = []
        for block in blocks {
            if let last = merged.last, block.0 <= last.1 { merged[merged.count - 1] = (last.0, max(last.1, block.1), last.2 + block.2) }
            else { merged.append(block) }
        }
        var cursor = start; var free: [JSON] = []
        for block in merged { if cursor < block.0 { free.append(.object(["start": .string(iso(cursor)), "end": .string(iso(block.0))])) }; cursor = max(cursor, block.1) }
        if cursor < end { free.append(.object(["start": .string(iso(cursor)), "end": .string(iso(end))])) }
        result["busy"] = .array(merged.map { .object(["start": .string(iso($0.0)), "end": .string(iso($0.1)), "event_ids": .array($0.2)]) })
        result["free"] = .array(free); result["snapshot_only"] = .bool(true)
        result["policy"] = .string("Exclude cancelled and free; count busy, tentative, unavailable and unknown. Snapshot only; no reservation.")
        return .object(result)
    }
    func checkWritable(_ calendar: JSON, event: EventRecord? = nil) throws {
        guard calendar["writable"].boolean == true, calendar["subscribed"].boolean == false else { throw CoreError("read_only", "Calendar is read-only or subscribed") }
        if let event {
            guard !event.hasAttendees, !event.hasOrganizer else { throw CoreError("unsupported_meeting", "Meeting/invitation mutations are unsupported") }
            guard event.details["unsupported_external_alarm"].boolean != true else { throw CoreError("unsupported_alarm", "Events with email or procedure alarms cannot be mutated") }
            guard !(event.recurring || event.detached) || event.occurrence != nil else { throw CoreError("ambiguous_occurrence", "Recurring event needs a unique occurrence") }
            guard event.status != "cancelled" else { throw CoreError("unsupported_event", "Cancelled events cannot be mutated") }
        }
    }
    private func preflight(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["action", "scope", "calendar_id", "event_id", "fields", "cutoff"], required: ["action", "scope"])
        let action = try a.string("action")
        let scope = try a.string("scope")
        if a.values["fields"]?.object?["all_day_dates"] != nil || (action == "create" && a.values["fields"]?["all_day"] == .bool(true)) { return try preflightAllDay(arguments) }
        if action == "delete", scope == "future" { return try preflightTermination(arguments) }
        if action == "modify", scope == "future" { return try preflightFuture(arguments) }
        if action == "modify", scope == "series" { return try preflightSeries(arguments) }
        guard a.values["cutoff"] == nil else { throw CoreError("invalid_arguments", "A cutoff is only valid for future termination") }
        guard ["create", "modify", "delete"].contains(action), scope == "this" || (action == "create" && scope == "series") else { throw CoreError("unsupported_scope", "Create a series or address one individual event or occurrence") }
        let calendar: JSON; let before: JSON; let after: JSON
        if action == "create" {
            guard a.values["event_id"] == nil, let patch = a.values["fields"] else { throw CoreError("invalid_arguments", "Create requires fields and a calendar, without event_id") }
            let id = try a.string("calendar_id")
            guard let pair = try calendars().first(where: { $0.1["id"].string == id }) else { throw CoreError("calendar_missing", "Unknown calendar") }
            calendar = pair.1; try checkWritable(calendar)
            let fields = try EventFields.merged(patch, with: nil)
            guard (scope == "series") == (fields.recurrence != nil) else { throw CoreError("unsupported_scope", "Series creation requires recurrence and scope series; individual creation uses scope this") }
            guard fields.timeZone != nil else { throw CoreError("unsupported_timezone", "New events require an explicit timezone") }
            before = .null; after = fields.json
        } else {
            guard a.values["calendar_id"] == nil else { throw CoreError("invalid_arguments", "Calendar moves are unsupported") }
            let record = try event(a.string("event_id")); before = try view(record); calendar = before["calendar"]
            try checkWritable(calendar, event: record)
            if action == "delete" {
                guard a.values["fields"] == nil else { throw CoreError("invalid_arguments", "Delete does not accept fields") }
                try checkRestorable(record, allowStandaloneOccurrence: true)
                after = .null
            } else {
                guard let patch = a.values["fields"] else { throw CoreError("invalid_arguments", "Modify requires fields") }
                let fields = try EventFields.merged(patch, with: record.fields)
                if fields.allDay {
                    guard ["start", "end", "time_zone", "all_day"].allSatisfy({ fields.json[$0] == record.fields.json[$0] }) else { throw CoreError("unsupported_all_day", "All-day structural edits require all_day_dates on one nonrecurring floating all-day event") }
                }
                after = fields.json
                let sameAlerts = try fields.alerts.map { try EventAlert.matches($0, raw: record.details["alarms"] == .null ? .array([]) : record.details["alarms"]) } ?? true
                guard fields.withoutAlerts != record.fields.withoutAlerts || !sameAlerts else { throw CoreError("no_change", "No event fields changed") }
                if fields.alerts != nil && !sameAlerts { try validateRestorableAlarms(recoveryDetails(record.details)["alarms"]) }
                if record.details["structured_location"] != .null && after["location"] != record.fields.json["location"] {
                    throw CoreError("unsupported_location", "Changing a structured location is unsupported; unrelated location data must be preserved")
                }
            }
        }
        let issued = now()
        let safety = try state.writeSafety(action: action, now: issued)
        let envelope: JSON = .object(["version": .int(3), "nonce": .string(UUID().uuidString), "issued_at": .string(iso(issued)), "expires_at": .string(iso(issued.addingTimeInterval(600))), "installation_id": .string(try requiredMetadata("installation_id")), "credential_generation": .string(try requiredMetadata("credential_generation")), "key_id": .string(try requiredMetadata("key_id")), "action": .string(action), "scope": .string(scope), "calendar": calendar, "before": before, "after": after, "recovery": recoveryContract(action: action, before: before)])
        guard try envelope.data().count <= 262_144 else { throw CoreError("preview_too_large", "Event review exceeds native preview limit") }
        let tag = HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: try signingKey())
        return .object(["preview": .object(["envelope": envelope, "authentication_tag": .string(Data(tag).base64EncodedString())]), "safety": safety])
    }
    func requiredMetadata(_ key: String) throws -> String {
        guard let value = try state.metadata(key) else { throw CoreError("state_corrupt", "Native identity configuration missing") }; return value
    }
    func signingKey() throws -> SymmetricKey {
        guard let data = Data(base64Encoded: try requiredMetadata("signing_key")), data.count == 32 else { throw CoreError("state_corrupt", "Native signing configuration invalid") }; return SymmetricKey(data: data)
    }
    func commit(_ arguments: JSON, action: String, rollback: Bool = false) throws -> JSON {
        if arguments["preview"]["envelope"]["version"] == .int(7) { return try commitAllDay(arguments, action: action, rollback: rollback) }
        let a = try Arguments(arguments, allowed: ["preview"], required: ["preview"])
        let p = try Arguments(a.values["preview"]!, allowed: ["envelope", "authentication_tag"], required: ["envelope", "authentication_tag"])
        let envelope = p.values["envelope"]!
        var keys: Set<String> = ["version", "nonce", "issued_at", "expires_at", "installation_id", "credential_generation", "key_id", "action", "scope", "calendar", "before", "after"]
        if rollback { keys.insert("rollback") }
        if envelope["version"] == .int(3) { keys.insert("recovery") }
        let e = try Arguments(envelope, allowed: keys, required: keys)
        guard try envelope.data().count <= 262_144, (rollback ? [1, 2] : [1, 2, 3]).contains(envelope["version"].integer ?? 0),
              let tag = Data(base64Encoded: try p.string("authentication_tag")), tag.count == 32,
              try e.string("installation_id") == requiredMetadata("installation_id"),
              try e.string("credential_generation") == requiredMetadata("credential_generation"),
              try e.string("key_id") == requiredMetadata("key_id"),
              HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: try envelope.data(), using: try signingKey()),
              try e.string("action") == action else { throw CoreError("invalid_preview", "Preview integrity, binding or action validation failed") }
        let version = envelope["version"].integer!, scope = try e.string("scope")
        guard scope == "this" || (version == 3 && !rollback && action == "create" && scope == "series"),
              version != 3 || envelope["recovery"] == recoveryContract(action: action, before: envelope["before"]) else { throw CoreError("invalid_preview", "Preview scope or recovery declaration is invalid") }
        if envelope["after"].object?["recurrence"] != nil {
            guard version == 3, !rollback, action == "create", scope == "series" else { throw CoreError("invalid_preview", "Recurrence is only supported for version-3 series creation") }
        } else if scope == "series" { throw CoreError("invalid_preview", "Series creation requires recurrence") }
        if envelope["version"] == .int(1), envelope["after"].object?["alerts"] != nil { throw CoreError("invalid_preview", "Legacy previews cannot contain alert directives") }
        if version >= 2, action == "create", !rollback, envelope["after"].object?["alerts"] == nil { throw CoreError("invalid_preview", "Create preview must specify the complete alert list") }
        let nonce = try e.string("nonce")
        guard UUID(uuidString: nonce) != nil else { throw CoreError("invalid_preview", "Invalid nonce") }
        if let prior = try state.execution(nonce) {
            guard try state.payloadMatches(nonce: nonce, payload: envelope) else { throw CoreError("nonce_conflict", "Nonce payload differs from recorded execution") }
            try state.recordCommitObservation(replayed: true, operation: rollback ? "commit_rollback" : "commit_" + action, now: now())
            return prior.result
        }
        if envelope["after"]["all_day"] == .bool(true) {
            let structural = action == "create" || ["start", "end", "time_zone", "all_day"].contains { envelope["after"][$0] != envelope["before"]["fields"][$0] }
            guard !structural else { throw CoreError("fresh_preview_required", "All-day structural writes require a fresh civil-date preview") }
        }
        let issued = try parseDate(e.string("issued_at")), expiry = try parseDate(e.string("expires_at")), current = now()
        guard issued <= current.addingTimeInterval(30), expiry > current, expiry > issued, expiry.timeIntervalSince(issued) <= 600.001 else { throw CoreError("preview_expired", "Preview expired or invalid; request a new preflight") }
        try state.assertNoUnresolvedConflict(payload: envelope)
        if rollback { try validateRollback(envelope) }
        let calendarID = try Arguments(envelope["calendar"], allowed: ["id", "title", "source", "writable", "subscribed"], required: ["id", "title", "source", "writable", "subscribed"]).string("id")
        guard let pair = try calendars().first(where: { $0.1["id"].string == calendarID }), pair.1 == envelope["calendar"] else { throw CoreError("stale_calendar", "Calendar changed; request a new preflight") }
        var existing: EventRecord?
        if action != "create" {
            guard let id = envelope["before"]["id"].string else { throw CoreError("invalid_preview", "Missing target event") }
            existing = try event(id)
            guard EventSnapshot.equivalent(try view(existing!), envelope["before"]) else { throw CoreError("stale_event", "Event changed; request a new preflight") }
        } else { guard envelope["before"] == .null else { throw CoreError("invalid_preview", "Unexpected create before state") } }
        try checkWritable(pair.1, event: existing)
        if action == "delete", let existing { try checkRestorable(existing, allowStandaloneOccurrence: hasStandaloneCopyRecoveryContract(envelope)) }
        let fields = envelope["after"] == .null ? nil : try EventFields(json: envelope["after"])
        guard (action == "delete") == (fields == nil) else { throw CoreError("invalid_preview", "Action and after state disagree") }
        if let fields {
            if let existing { _ = try fields.dates(preserving: existing.fields) }
            else { _ = try fields.dates() }
            if let recurrence = fields.recurrence { guard envelope["after"]["recurrence"] == recurrence.json else { throw CoreError("invalid_preview", "Recurrence intent must be canonical") } }
            if fields.alerts != nil, let existing { try validateRestorableAlarms(recoveryDetails(existing.details)["alarms"]) }
        }
        let auditSequence = try state.claim(nonce: nonce, payload: envelope, now: current)
        let result: JSON
        var verificationStage: WriteFailureStage = .providerMutation
        do {
            let written: EventRecord?
            if rollback && action == "create", let fields {
                written = try providerMutation { try backend.restore(calendarID: pair.0.nativeID, fields: fields, details: envelope["rollback"]["restoration"]["details"], availability: envelope["rollback"]["restoration"]["availability"].string!) }
            } else if rollback && action == "modify", let existing, let fields, envelope["rollback"].object?["alarm_restoration"] != nil {
                written = try providerMutation { try backend.applyRestoringAlarms(calendarID: pair.0.nativeID, existing: existing, fields: fields, alarms: envelope["rollback"]["alarm_restoration"]) }
            } else { written = try providerMutation { try backend.apply(action: action, calendarID: pair.0.nativeID, existing: existing, fields: fields) } }
            verificationStage = .resultVerification
            if action == "delete" {
                verificationStage = .boundaryAbsence
                guard let existing else { throw CoreError("verification_failed", "Missing delete identity") }
                do { _ = try backend.get(nativeID: existing.nativeID, calendarID: existing.calendarNativeID, occurrence: existing.occurrence, knownStart: parseDate(existing.fields.start)); throw CoreError("verification_failed", "Deleted event still resolves") }
                catch let error as CoreError where error.code == "event_missing" { }
                result = .object(["nonce": .string(nonce), "state": .string("applied"), "action": .string(action), "deleted": .bool(true), "audit_sequence": .int(auditSequence)])
            } else {
                guard let written, let fields else { throw CoreError("verification_failed", "Write returned no event") }
                let refreshed = try backend.get(nativeID: written.nativeID, calendarID: written.calendarNativeID, occurrence: written.occurrence, knownStart: parseDate(written.fields.start))
                guard refreshed.fields.withoutAlerts == fields.withoutAlerts, refreshed.calendarNativeID == pair.0.nativeID else { throw CoreError("verification_failed", "Written event differs from preview") }
                if let recurrence = fields.recurrence {
                    guard refreshed.recurring, !refreshed.detached, refreshed.occurrence != nil, recurrence.matches(raw: refreshed.details["recurrence_rules"]) else { throw CoreError("verification_failed", "Created series recurrence differs from preview") }
                } else if action == "create" {
                    guard !refreshed.recurring, !refreshed.detached, refreshed.occurrence == nil,
                          refreshed.details["recurrence_rules"] == .null || refreshed.details["recurrence_rules"] == .array([]) else { throw CoreError("verification_failed", "Unexpected recurrence on individual creation") }
                }
                if rollback, let alarms = envelope["rollback"].object?["alarm_restoration"] {
                    guard EventSnapshot.alarmsEquivalent(refreshed.details["alarms"], alarms) else { throw CoreError("verification_failed", "Restored alarms differ from the signed review") }
                } else if let alerts = fields.alerts {
                    guard try EventAlert.matches(alerts, raw: refreshed.details["alarms"]) else { throw CoreError("verification_failed", "Written alerts differ from preview") }
                }
                if let existing {
                    var preservedKeys = ["url", "structured_location", "attendees", "organizer"]
                    if fields.alerts == nil && envelope["rollback"].object?["alarm_restoration"] == nil { preservedKeys.append("alarms") }
                    for key in preservedKeys {
                        guard key == "alarms" ? EventSnapshot.alarmsEquivalent(refreshed.details[key], existing.details[key]) : refreshed.details[key] == existing.details[key] else { throw CoreError("verification_failed", "Unrelated event details changed during write") }
                    }
                    guard existing.recurring || existing.detached || refreshed.details["recurrence_rules"] == existing.details["recurrence_rules"] else { throw CoreError("verification_failed", "Unexpected recurrence change") }
                    try state.rebindEvent(id: envelope["before"]["id"].string!, to: refreshed)
                }
                if rollback {
                    let sources = envelope["rollback"]["source_change_ids"]
                    let source = try state.execution(sources.array!.first!.string!)!.payload
                    let originalID = source["before"]["id"].string!
                    if action == "create" {
                        guard EventSnapshot.detailsEquivalent(recoveryDetails(refreshed.details), envelope["rollback"]["restoration"]["details"]), refreshed.availability == envelope["rollback"]["restoration"]["availability"].string else { throw CoreError("verification_failed", "Restored event details differ from the signed review") }
                        try state.rebindEvent(id: originalID, to: refreshed)
                    }
                    result = .object(["nonce": .string(nonce), "state": .string("applied"), "action": .string(action), "event": try view(refreshed), "event_id": .string(originalID), "rollback_of": sources, "audit_sequence": .int(auditSequence)])
                } else { result = .object(["nonce": .string(nonce), "state": .string("applied"), "action": .string(action), "event": try view(refreshed), "audit_sequence": .int(auditSequence)]) }
            }
        } catch {
            return writeFailure(error, nonce: nonce, action: action, sequence: auditSequence, stage: verificationStage)
        }
        do { try state.finish(nonce: nonce, state: "applied", result: result, event: "write_applied"); return result }
        catch { return unknownWrite(error, nonce: nonce, action: action, sequence: auditSequence, stage: .outcomePersistence) }
    }
}
