import Foundation
import CryptoKit

extension StateStore {
    func recoveryRows() throws -> [[String]] { try rows("SELECT e.nonce,e.payload,e.state,e.result,e.created,d.expires,d.expired,e.rowid FROM executions e LEFT JOIN execution_details d ON d.nonce=e.nonce ORDER BY e.rowid") }
    func rollbackOwner(_ nonce: String) throws -> String? { try rows("SELECT rollback_nonce FROM recovery_links WHERE source_nonce=?", [nonce]).first?.first }
}

extension Broker {
    func recoveryDetails(_ details: JSON) -> JSON {
        .object(["url": details["url"], "alarms": details["alarms"].array.map(JSON.array) ?? .array([]), "structured_location": details["structured_location"]])
    }
    func checkRestorable(_ record: EventRecord, allowStandaloneOccurrence: Bool = false) throws {
        guard (!record.recurring && !record.detached) || (allowStandaloneOccurrence && record.occurrence != nil) else { throw CoreError("unsupported_restore", "Deleting recurring or detached events needs the explicit standalone-copy recovery contract") }
        guard !record.hasAttendees, !record.hasOrganizer, record.status != "cancelled", record.details["unsupported_external_alarm"] != .bool(true), record.details["alarms"] == .null || record.details["alarms"].array != nil else { throw CoreError("unsupported_restore", "Stored meeting, alarm or status data cannot be faithfully restored") }
        _ = try record.fields.normalized()
        guard ["free", "busy", "tentative", "unavailable", "unknown"].contains(record.availability) else { throw CoreError("unsupported_restore", "Unsupported event availability") }
        let details = recoveryDetails(record.details)
        if details["url"] != .null { guard let text = details["url"].string, URL(string: text) != nil else { throw CoreError("unsupported_restore", "Invalid event URL") } }
        try validateRestorableLocation(details["structured_location"])
        try validateRestorableAlarms(details["alarms"])
    }
    func validateRestorableLocation(_ value: JSON) throws {
        if value == .null { return }
        guard let object = value.object, Set(object.keys).isSubset(of: ["title", "radius", "latitude", "longitude"]), value["title"] == .null || value["title"].string != nil,
              let radius = value["radius"].string.flatMap(Double.init), radius.isFinite, radius >= 0 else { throw CoreError("unsupported_restore", "Unsupported structured location") }
        if value["latitude"] != .null || value["longitude"] != .null {
            guard let latitude = value["latitude"].string.flatMap(Double.init), let longitude = value["longitude"].string.flatMap(Double.init), latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw CoreError("unsupported_restore", "Unsupported geographic location") }
        }
    }
    func validateRestorableAlarms(_ raw: JSON) throws {
        guard let alarms = raw.array else { throw CoreError("unsupported_restore", "Retained alarms must be an array") }
        for alarm in alarms {
            guard let type = alarm["type"].integer, [0, 1].contains(type), let proximity = alarm["proximity"].integer, (0...2).contains(proximity), let offset = alarm["relative_offset"].string.flatMap(Double.init), offset.isFinite,
                  alarm["email_address"] == .null, alarm["sound_name"] == .null || alarm["sound_name"].string != nil else { throw CoreError("unsupported_restore", "Unsupported retained alarm") }
            guard (type == 0 && alarm["sound_name"] == .null) || (type == 1 && alarm["sound_name"].string != nil) else { throw CoreError("unsupported_restore", "Alarm type and sound do not form a restorable alarm") }
            if let date = alarm["absolute_date"].string { _ = try parseDate(date) }
            else if alarm["absolute_date"] != .null { throw CoreError("unsupported_restore", "Invalid absolute alarm date") }
            try validateRestorableLocation(alarm["structured_location"])
        }
    }
    public func maintainRecoveryDetails() -> JSON {
        lock.lock(); defer { lock.unlock() }
        do { try state.expireRecoveryDetails(now: now()); return .object(["maintained": .bool(true)]) }
        catch { return .object(["maintained": .bool(false)]) }
    }
    func changeSummary(_ row: [String], held suppliedHeld: Set<String>? = nil) throws -> JSON {
        let marker = try JSON.parse(Data(row[1].utf8)), owner = try state.rollbackOwner(row[0]), retained = row[6] == "0", held = try (suppliedHeld ?? state.recoveryHeldNonces()).contains(row[0])
        var reason: String? = nil
        if marker["rollback_of"].array != nil { reason = "rollback_execution" }
        else if !["modify", "delete"].contains(marker["action"].string ?? "") { reason = "not_a_modification_or_deletion" }
        else if row[2] != "applied" { reason = "outcome_not_verified_applied" }
        else if owner != nil { reason = "already_rolled_back" }
        else if held { reason = "dependent_outcome_unresolved" }
        else if !retained { reason = "details_expired" }
        else if let payload = try state.execution(row[0])?.payload, marker["action"] == .string("delete"), payload["before"]["recurring"] == .bool(true) || payload["before"]["detached"] == .bool(true), !hasStandaloneCopyRecoveryContract(payload) { reason = "recurring_deletion_cannot_be_faithfully_restored" }
        var value: [String: JSON] = ["change_id": .string(row[0]), "created_at": .string(row[4]), "action": marker["action"], "state": .string(row[2]), "event_id": marker["event_id"], "expires_at": .optional(row[5].isEmpty ? nil : row[5]), "details_expired": .bool(!retained), "retention_hold": .bool(held), "rolled_back_by": .optional(owner), "recovery_eligible": .bool(reason == nil), "recovery_reason": .optional(reason)]
        if retained, let payload = try state.execution(row[0])?.payload, let title = payload["before"]["fields"]["title"].string { value["title"] = .string(String(title.unicodeScalars.prefix(300))); value["title_truncated"] = .bool(title.unicodeScalars.count > 300) }
        if marker["rollback_of"].array != nil { value["rollback_of"] = marker["rollback_of"] }
        return .object(value)
    }
    func validatedFilters(_ arguments: JSON, allowSelection: Bool = false) throws -> JSON {
        var allowed: Set<String> = ["since", "until", "action", "event_id", "include_expired", "limit", "cursor"]
        if allowSelection { allowed = ["all", "since", "until", "action", "event_id"] }
        let a = try Arguments(arguments, allowed: allowed)
        var filters: [String: JSON] = [:]
        for key in ["since", "until"] { if a.values[key] != nil { filters[key] = .string(iso(try parseDate(a.string(key)))) } }
        if let since = filters["since"]?.string, let until = filters["until"]?.string, since >= until { throw CoreError("invalid_arguments", "since must be earlier than until") }
        if a.values["action"] != nil { let action = try a.string("action"); guard ["modify", "delete"].contains(action) else { throw CoreError("invalid_arguments", "History action must be modify or delete") }; filters["action"] = .string(action) }
        if a.values["event_id"] != nil { let id = try a.string("event_id"); guard UUID(uuidString: id) != nil else { throw CoreError("invalid_arguments", "Invalid event identity") }; filters["event_id"] = .string(id) }
        let include = a.values["include_expired"] ?? .bool(false)
        guard include.boolean != nil else { throw CoreError("invalid_arguments", "include_expired must be boolean") }
        filters["include_expired"] = include
        return .object(filters)
    }
    func matchingRows(_ filters: JSON, snapshot: String? = nil, heldMembership: Set<String>? = nil) throws -> [[String]] {
        let held = try heldMembership ?? state.recoveryHeldNonces()
        return try state.recoveryRows().filter { row in
            let marker = try JSON.parse(Data(row[1].utf8))
            guard ["modify", "delete"].contains(marker["action"].string ?? ""), marker["rollback_of"] == .null else { return false }
            if let since = filters["since"].string, row[4] < since { return false }
            if let until = filters["until"].string, row[4] >= until { return false }
            if filters["action"] != .null, marker["action"] != filters["action"] { return false }
            if filters["event_id"] != .null, marker["event_id"] != filters["event_id"] { return false }
            if let snapshot { return filters["include_expired"] == .bool(true) || row[5] > snapshot || held.contains(row[0]) }
            return filters["include_expired"] == .bool(true) || row[6] == "0"
        }
    }
    func listChanges(_ arguments: JSON) throws -> JSON {
        let filters = try validatedFilters(arguments)
        let limit = arguments["limit"] == .null ? 50 : arguments["limit"].integer ?? 0
        guard (1...100).contains(limit) else { throw CoreError("invalid_arguments", "History limit must be 1 through 100") }
        let allRows = try state.recoveryRows()
        var cutoff = Int(allRows.last?[7] ?? "0") ?? 0, after = Int.max, snapshot = iso(now())
        var heldMembership = try state.recoveryHeldNonces()
        if arguments["cursor"] != .null {
            guard let cursor = arguments["cursor"].string, cursor.count <= 4096, let data = Data(base64Encoded: cursor) else { throw CoreError("invalid_cursor", "Invalid history cursor") }
            let wrapper = try JSON.parse(data), body = wrapper["body"]
            guard let tag = wrapper["tag"].string.flatMap({ Data(base64Encoded: $0) }), HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: try body.data(), using: try signingKey()), body["filters"] == filters,
                  let c = body["cutoff"].integer, let a = body["after"].integer, let s = body["snapshot_at"].string else { throw CoreError("invalid_cursor", "History cursor does not match filters or installation") }
            cutoff = c; after = a; snapshot = s
            guard let held = body["held_ids"].array, held.allSatisfy({ $0.string != nil }) else { throw CoreError("invalid_cursor", "Invalid held membership") }
            heldMembership = Set(held.compactMap(\.string))
        }
        let rows = try matchingRows(filters, snapshot: snapshot, heldMembership: heldMembership).reversed().filter { (Int($0[7]) ?? 0) <= cutoff && (Int($0[7]) ?? 0) < after }
        let currentHeld = try state.recoveryHeldNonces()
        var page: [[String]] = [], summaries: [JSON] = [], bytes = 0
        for row in rows.prefix(limit) {
            let summary = try changeSummary(row, held: currentHeld), count = try summary.data().count
            if bytes + count > 400 * 1024 {
                guard !page.isEmpty else { throw CoreError("history_entry_too_large", "Stored summary exceeds native response bound") }; break
            }
            page.append(row); summaries.append(summary); bytes += count
        }
        var cursor: JSON = .null
        if rows.count > page.count, let last = page.last {
            let body: JSON = .object(["filters": filters, "cutoff": .int(cutoff), "after": .int(Int(last[7])!), "snapshot_at": .string(snapshot), "held_ids": .array(heldMembership.sorted().map(JSON.string))])
            let tag = HMAC<SHA256>.authenticationCode(for: try body.data(), using: try signingKey())
            cursor = .string(try JSON.object(["body": body, "tag": .string(Data(tag).base64EncodedString())]).data().base64EncodedString())
        }
        return .object(["changes": .array(summaries), "next_cursor": cursor, "snapshot_at": .string(snapshot), "retention_policy": try state.recoveryPolicy()])
    }
    func storedChange(_ arguments: JSON) throws -> JSON {
        let a = try Arguments(arguments, allowed: ["change_id"], required: ["change_id"]), id = try a.string("change_id")
        guard UUID(uuidString: id) != nil, let row = try state.recoveryRows().first(where: { $0[0] == id }), let execution = try state.execution(id) else { throw CoreError("change_missing", "Stored change is unavailable") }
        return .object(["change": try changeSummary(row), "before": execution.payload["before"], "proposed_after": execution.payload["after"], "observed_after": execution.result["event"], "execution_result": execution.result])
    }
    func selectedRows(_ arguments: JSON) throws -> [[String]] {
        if arguments["change_ids"] != .null {
            _ = try Arguments(arguments, allowed: ["change_ids"], required: ["change_ids"])
            guard let values = arguments["change_ids"].array, (1...25).contains(values.count), values.allSatisfy({ $0.string.flatMap(UUID.init(uuidString:)) != nil }), Set(values.compactMap(\.string)).count == values.count else { throw CoreError("invalid_selection", "Select 1 through 25 unique change IDs") }
            let ids = Set(values.compactMap(\.string)), rows = try state.recoveryRows().filter { ids.contains($0[0]) }
            guard rows.count == ids.count else { throw CoreError("change_missing", "A selected stored change is unavailable") }; return rows
        }
        let filters = try validatedFilters(arguments, allowSelection: true)
        guard arguments["all"] == .bool(true) else { throw CoreError("invalid_selection", "Provide change_ids or all:true with optional filters") }
        let rows = try matchingRows(filters).filter { try state.rollbackOwner($0[0]) == nil }
        guard !rows.isEmpty else { throw CoreError("empty_selection", "No eligible retained changes match") }
        guard rows.count <= 25 else { throw CoreError("selection_too_large", "More than 25 changes match; narrow the filters or select an explicit batch") }
        return rows
    }
    func sourceDigest(_ rows: [[String]]) throws -> String {
        try digest(JSON.array(rows.map { row in
            guard let execution = try state.execution(row[0]) else { throw CoreError("change_missing", "Stored source missing") }
            return .object(["change_id": .string(row[0]), "payload": execution.payload, "result": execution.result])
        }).data())
    }
    func validateHistoryBridges(_ all: [[String]], eventID: String, startingAt rowID: Int) throws {
        let history = try all.filter { row in
            let marker = try JSON.parse(Data(row[1].utf8))
            return marker["event_id"] == .string(eventID) && (Int(row[7]) ?? 0) >= rowID
        }
        var previousAfter: JSON?, previousAction: String?
        for row in history {
            guard row[2] == "applied", row[6] == "0", let execution = try state.execution(row[0]), execution.payload["storage_version"] == .null else { throw CoreError("rollback_history_gap", "Historical bridge evidence is expired or unverified; inspect this event locally") }
            let action = execution.payload["action"].string!
            if let previousAfter {
                if action == "create" {
                    guard previousAction == "delete", execution.payload["before"] == .null, execution.payload["rollback"]["source_change_ids"].array != nil else { throw CoreError("rollback_history_gap", "Event recreation has no verified integration deletion bridge") }
                } else {
                    guard execution.payload["before"] == previousAfter else { throw CoreError("rollback_history_gap", "An external or untracked event change separates the selected history; rollback would overwrite it") }
                }
            }
            previousAfter = action == "delete" ? .null : execution.result["event"]
            previousAction = action
            guard action == "delete" || previousAfter != .null else { throw CoreError("rollback_history_gap", "Verified observed state is unavailable") }
        }
    }
    func rollbackStep(_ sources: [[String]], selectionID: String, validateAlarmRestoration: Bool = true) throws -> JSON {
        guard let first = sources.first, let last = sources.last, sources.count <= 25 else { throw CoreError("invalid_selection", "Empty rollback group") }
        let held = try state.recoveryHeldNonces()
        for row in sources { guard try changeSummary(row, held: held)["recovery_eligible"] == .bool(true) else { throw CoreError("rollback_ineligible", "A selected change is expired, unverified, consumed or unsupported") } }
        let marker = try JSON.parse(Data(first[1].utf8)), eventID = marker["event_id"].string!
        let all = try state.recoveryRows(), active = try all.filter { row in
            let m = try JSON.parse(Data(row[1].utf8))
            let owner = try state.rollbackOwner(row[0])
            return m["event_id"] == .string(eventID) && m["rollback_of"] == .null && ["modify", "delete"].contains(m["action"].string ?? "") && owner == nil
        }
        guard Array(active.suffix(sources.count)).map({ $0[0] }) == sources.map({ $0[0] }) else { throw CoreError("rollback_lineage", "Select a contiguous suffix of the event's remaining changes, including newer changes") }
        try validateHistoryBridges(all, eventID: eventID, startingAt: Int(first[7])!)
        guard let original = try state.execution(first[0])?.payload, let latest = try all.last(where: { row in
            let m = try JSON.parse(Data(row[1].utf8)); return m["event_id"] == .string(eventID)
        }), latest[2] == "applied", let latestExecution = try state.execution(latest[0]) else { throw CoreError("rollback_lineage", "Latest integration outcome is not verified") }
        let desired = original["before"], calendar = desired["calendar"]
        guard let currentCalendar = try calendars().first(where: { $0.1["id"] == calendar["id"] }), currentCalendar.1 == calendar else { throw CoreError("stale_calendar", "Original calendar changed or is unavailable") }
        let action: String, before: JSON, restoration: JSON
        var restoresOccurrenceCopy = false
        if latestExecution.payload["action"] == .string("delete") {
            do { _ = try event(eventID); throw CoreError("stale_event", "Deleted event resolves again; inspect before restoring") }
            catch let error as CoreError where error.code == "event_missing" { }
            restoresOccurrenceCopy = desired["recurring"] == .bool(true) || desired["detached"] == .bool(true)
            guard !restoresOccurrenceCopy || hasStandaloneCopyRecoveryContract(latestExecution.payload) else { throw CoreError("unsupported_restore", "Historical recurring deletions lack the standalone-copy recovery contract") }
            // A new standalone intended state; the authoritative source snapshot stays immutable.
            let restored = EventRecord(nativeID: "stored", calendarNativeID: currentCalendar.0.nativeID, fields: try EventFields(json: desired["fields"]), recurring: false, detached: false, hasAttendees: desired["has_attendees"].boolean ?? true, hasOrganizer: desired["has_organizer"].boolean ?? true, availability: desired["availability"].string ?? "unsupported", status: desired["status"].string ?? "cancelled", details: recoveryDetails(desired["details"]))
            try checkRestorable(restored)
            action = "create"; before = .null
            restoration = .object(["details": recoveryDetails(desired["details"]), "availability": desired["availability"]])
        } else {
            let current = try event(eventID); before = try view(current)
            guard before == latestExecution.result["event"] else { throw CoreError("stale_event", "Current event differs from the latest verified integration outcome") }
            try checkWritable(calendar, event: current); action = "modify"; restoration = .null
        }
        try checkWritable(calendar)
        let fields = try EventFields(json: desired["fields"]); _ = try fields.dates()
        if validateAlarmRestoration { try validateRestorableAlarms(recoveryDetails(desired["details"])["alarms"]) }
        let issued = now(), expiry = try sources.map { try parseDate($0[5]) }.min()!
        guard expiry > issued else { throw CoreError("rollback_ineligible", "A selected source has expired") }
        var limitations: [JSON] = action == "create" ? [.string(Self.copyRecoveryLimitation)] : []
        if restoresOccurrenceCopy { limitations.append(.string(Self.recurringCopyRecoveryLimitation)) }
        if action == "modify" && [desired["recurring"], desired["detached"], before["recurring"], before["detached"]].contains(.bool(true)) {
            limitations.append(.string(Self.occurrenceRecoveryLimitation))
        }
        let rollback: JSON = .object(["alarm_restoration": recoveryDetails(desired["details"])["alarms"], "selection_id": .string(selectionID), "source_change_ids": .array(sources.map { .string($0[0]) }), "source_digest": .string(try sourceDigest(sources)), "restoration": restoration, "limitations": .array(limitations)])
        let envelope: JSON = .object(["version": .int(2), "nonce": .string(UUID().uuidString), "issued_at": .string(iso(issued)), "expires_at": .string(iso(min(issued.addingTimeInterval(600), expiry))), "installation_id": .string(try requiredMetadata("installation_id")), "credential_generation": .string(try requiredMetadata("credential_generation")), "key_id": .string(try requiredMetadata("key_id")), "action": .string(action), "scope": .string("this"), "calendar": calendar, "before": before, "after": fields.json, "rollback": rollback])
        guard try envelope.data().count <= 262_144 else { throw CoreError("preview_too_large", "Rollback review is too large") }
        let tag = HMAC<SHA256>.authenticationCode(for: try envelope.data(), using: try signingKey())
        _ = last
        return .object(["preview": .object(["envelope": envelope, "authentication_tag": .string(Data(tag).base64EncodedString())]), "safety": try state.writeSafety(action: action, now: issued)])
    }
    func preflightRollback(_ arguments: JSON) throws -> JSON {
        guard try !state.hasUnresolved() else { throw CoreError("unresolved_write", "Resolve earlier unknown outcomes before any rollback") }
        let rows = try selectedRows(arguments), selection = UUID().uuidString
        let grouped = try Dictionary(grouping: rows) { try JSON.parse(Data($0[1].utf8))["event_id"].string ?? "" }
        guard grouped[""] == nil else { throw CoreError("rollback_ineligible", "Selected change has no recoverable event identity") }
        let steps = try grouped.values.sorted { Int($0.first![7])! < Int($1.first![7])! }.map { try rollbackStep($0, selectionID: selection) }
        let result: JSON = .object(["selection_id": .string(selection), "selected_change_ids": .array(rows.map { .string($0[0]) }), "selected_count": .int(rows.count), "step_count": .int(steps.count), "steps": .array(steps), "atomic": .bool(false), "limitations": .array([.string("Each event step is a separate durable write. Stop after a failure or unknown outcome; applied steps are not automatically reversed.")])])
        guard try result.data().count <= 450 * 1024 else { throw CoreError("selection_too_large", "Rollback response exceeds the review bound; narrow the selection") }
        return result
    }
    func validateRollback(_ envelope: JSON) throws {
        var rollbackKeys: Set<String> = ["selection_id", "source_change_ids", "source_digest", "restoration", "limitations"]
        if envelope["version"] == .int(2) { rollbackKeys.insert("alarm_restoration") }
        let r = try Arguments(envelope["rollback"], allowed: rollbackKeys, required: rollbackKeys)
        let selection = try r.string("selection_id")
        guard UUID(uuidString: selection) != nil else { throw CoreError("invalid_preview", "Invalid selection identity") }
        let rows = try selectedRows(.object(["change_ids": envelope["rollback"]["source_change_ids"]]))
        var expected = try rollbackStep(rows, selectionID: selection, validateAlarmRestoration: envelope["version"] == .int(2))["preview"]["envelope"]
        if envelope["version"] == .int(1) {
            var value = expected.object!, rollback = expected["rollback"].object!; rollback.removeValue(forKey: "alarm_restoration"); value["rollback"] = .object(rollback); expected = .object(value)
        }
        for key in ["action", "calendar", "before", "after", "rollback"] { guard envelope[key] == expected[key] else { throw CoreError("stale_rollback", "Rollback sources, lineage or current event changed; request a new review") } }
    }
    /// Only the resident native control calls this entry point with the preview it displayed.
    /// Transport dispatch cannot choose or override the consent source.
    public func commitReviewedRollback(_ preview: JSON) -> JSON {
        lock.lock(); defer { lock.unlock() }
        state.localNativeReview = true; defer { state.localNativeReview = false }
        do {
            try state.expireRecoveryDetails(now: now())
            guard let action = preview["envelope"]["action"].string, ["create", "modify"].contains(action) else { throw CoreError("invalid_preview", "Invalid rollback action") }
            return .object(["result": try commit(.object(["preview": preview]), action: action, rollback: true)])
        } catch {
            let e = error as? CoreError ?? CoreError("native_error", "Native rollback failed safely")
            do { try state.append(event: "commit_rejected", nonce: nil, payload: .object(["op": .string("commit_rollback"), "code": .string(e.code)])) }
            catch { return .object(["error": .object(["code": .string("audit_unavailable"), "message": .string("Cannot durably record rejected rollback")])]) }
            return .object(["error": .object(["code": .string(e.code), "message": .string(e.message)])])
        }
    }
}
