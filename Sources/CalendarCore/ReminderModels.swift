// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Civil reminder components, never an event interval or an implicit current-zone instant.
public struct ReminderDate: Equatable, Sendable {
    private static let namedZones = Set(TimeZone.knownTimeZoneIdentifiers).union(["UTC", "GMT"])
    public let date: String, time: String?, timeZone: String?
    public var json: JSON { .object(["date": .string(date), "time": .optional(time), "time_zone": .optional(timeZone)]) }
    public init(_ json: JSON) throws {
        let a = try Arguments(json, allowed: ["date", "time", "time_zone"], required: ["date", "time", "time_zone"])
        date = try a.string("date")
        guard json["time"] == .null || json["time"].string != nil, json["time_zone"] == .null || json["time_zone"].string != nil else { throw CoreError("invalid_reminder_date", "Reminder time and timezone must be explicit strings or null") }
        time = json["time"].string
        let requestedZone = json["time_zone"].string
        guard requestedZone == nil || Self.namedZones.contains(requestedZone!) else { throw CoreError("invalid_reminder_date", "Use a known IANA reminder timezone") }
        timeZone = requestedZone.flatMap(TimeZone.init(identifier:))?.identifier
        do { _ = try AllDayInterval.civilOrdinal(date) } catch { throw CoreError("invalid_reminder_date", "Reminder date must be a real Gregorian YYYY-MM-DD within years 0001 through 9999") }
        guard timeZone == nil || TimeZone(identifier: timeZone!) != nil else { throw CoreError("invalid_reminder_date", "Invalid reminder IANA timezone") }
        if let time {
            guard time.range(of: #"^[0-9]{2}:[0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil,
                  let h = Int(time.prefix(2)), let m = Int(time.dropFirst(3).prefix(2)), let s = Int(time.suffix(2)), h <= 23, m <= 59, s <= 59 else { throw CoreError("invalid_reminder_date", "Reminder time must be exact HH:MM:SS") }
            if let zone = timeZone.flatMap(TimeZone.init(identifier:)) { _ = try instant(zone: zone) }
        }
    }
    public func components() -> DateComponents {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var value = DateComponents(); value.calendar = calendar; value.era = 1
        value.year = Int(date.prefix(4)); value.month = Int(date.dropFirst(5).prefix(2)); value.day = Int(date.suffix(2))
        if let time { value.hour = Int(time.prefix(2)); value.minute = Int(time.dropFirst(3).prefix(2)); value.second = Int(time.suffix(2)) }
        value.timeZone = timeZone.flatMap(TimeZone.init(identifier:))
        return value
    }
    private func instant(zone: TimeZone) throws -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var expected = components(); expected.calendar = nil; expected.timeZone = nil
        let selected: Set<Calendar.Component> = [.era,.year,.month,.day,.hour,.minute,.second]
        guard let instant = calendar.date(from: expected), selected.allSatisfy({ calendar.component($0, from: instant) == expected.value(for: $0) }),
              calendar.nextDate(after: instant.addingTimeInterval(-172800), matching: expected, matchingPolicy: .strict, repeatedTimePolicy: .first) == instant,
              calendar.nextDate(after: instant.addingTimeInterval(-172800), matching: expected, matchingPolicy: .strict, repeatedTimePolicy: .last) == instant else { throw CoreError("invalid_reminder_date", "Reminder local time is nonexistent, ambiguous or normalized") }
        return instant
    }
    public static func validateLabel(_ value: String) throws { do { _ = try AllDayInterval.civilOrdinal(value) } catch { throw CoreError("invalid_reminder_date", "Use a real Gregorian reminder date") } }
}

public struct ReminderAlert: Equatable, Sendable {
    public let at: String
    public var json: JSON { .object(["at": .string(at)]) }
    public var rawAlarm: JSON { .object(["absolute_date": .string(at), "relative_offset": .string("0.0"), "proximity": .int(0), "structured_location": .null, "type": .int(0), "email_address": .null, "sound_name": .null]) }
    public static func parse(_ value: JSON) throws -> [ReminderAlert] {
        guard let array = value.array, array.count <= 10 else { throw CoreError("invalid_fields", "Use at most ten absolute reminder display alerts") }
        let result = try array.map { item -> ReminderAlert in
            let a = try Arguments(item, allowed: ["at"], required: ["at"])
            return ReminderAlert(at: iso(try parseDate(a.string("at"))))
        }.sorted { $0.at < $1.at }
        guard Set(result.map(\.at)).count == result.count else { throw CoreError("invalid_fields", "Duplicate reminder alerts") }; return result
    }
    public static func validateRaw(_ values: JSON) throws {
        guard let array = values.array, array.count <= 10 else { throw CoreError("unsupported_restore", "Unsupported reminder alarm restoration") }
        for value in array {
            guard let at = value["absolute_date"].string, let projected = try parse(.array([.object(["at": .string(at)])])).first,
                  value == projected.rawAlarm else { throw CoreError("unsupported_restore", "Only exact absolute display alarms can be recreated in Reminders v1") }
        }
    }
}

public struct ReminderFields: Equatable, Sendable {
    public let title: String, notes: String
    public let priority: Int
    public let start: ReminderDate?, due: ReminderDate?
    public var alerts: [ReminderAlert]?
    public var observedJSON: JSON { .object(["title": .string(title), "notes": .string(notes), "priority": .int(priority), "start": start?.json ?? .null, "due": due?.json ?? .null]) }
    public var json: JSON { var value = observedJSON.object!; if let alerts { value["alerts"] = .array(alerts.map(\.json)) }; return .object(value) }
    public var withoutAlerts: ReminderFields { var copy = self; copy.alerts = nil; return copy }
    public init(_ json: JSON, retained: Bool = false) throws {
        _ = try Arguments(json, allowed: ["title", "notes", "priority", "start", "due", "alerts"], required: ["title", "notes", "priority", "start", "due"])
        guard let title = json["title"].string, let notes = json["notes"].string, let priority = json["priority"].integer,
              (0...9).contains(priority), retained || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.unicodeScalars.count <= (retained ? 65536 : 1000), notes.unicodeScalars.count <= (retained ? 65536 : 10000) else { throw CoreError("invalid_reminder_fields", "Invalid reminder text or integer priority") }
        self.title = title; self.notes = notes; self.priority = priority
        alerts = try json.object?["alerts"].map(ReminderAlert.parse)
        start = try json["start"] == .null ? nil : ReminderDate(json["start"])
        due = try json["due"] == .null ? nil : ReminderDate(json["due"])
    }
    public static func merged(_ patch: JSON, with existing: ReminderFields?) throws -> ReminderFields {
        let a = try Arguments(patch, allowed: ["title", "notes", "priority", "start", "due", "alerts"])
        guard !a.values.isEmpty else { throw CoreError("invalid_reminder_fields", "At least one reminder field is required") }
        if let title = a.values["title"] { guard let value = title.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.unicodeScalars.count <= 1000 else { throw CoreError("invalid_reminder_fields", "Invalid reminder title") } }
        if let notes = a.values["notes"] { guard let value = notes.string, value.unicodeScalars.count <= 10000 else { throw CoreError("invalid_reminder_fields", "Invalid reminder notes") } }
        var full = existing?.json.object ?? ["notes": .string(""), "priority": .int(0), "start": .null, "due": .null, "alerts": .array([])]
        full.merge(a.values) { _, new in new }
        return try ReminderFields(.object(full), retained: existing != nil)
    }
}

public struct ReminderListRecord: Equatable, Sendable {
    public let nativeID: String, title: String, source: String
    public let writable: Bool
    public init(nativeID: String, title: String, source: String, writable: Bool = true) { self.nativeID = nativeID; self.title = title; self.source = source; self.writable = writable }
    public func view(id: String) -> JSON { .object(["id": .string(id), "title": .string(title), "source": .string(source), "writable": .bool(writable)]) }
}

public struct ReminderRecord: Equatable, Sendable {
    public var nativeID: String, listNativeID: String
    public var fields: ReminderFields
    public var completed: Bool
    public var completionDate: String?
    public var details: JSON
    public var unsupportedReasons: [String]
    public init(nativeID: String, listNativeID: String, fields: ReminderFields, completed: Bool = false, completionDate: String? = nil, details: JSON = .object([:]), unsupportedReasons: [String] = []) {
        self.nativeID = nativeID; self.listNativeID = listNativeID; self.fields = fields; self.completed = completed; self.completionDate = completionDate; self.details = details; self.unsupportedReasons = unsupportedReasons
    }
    public func exactCompletionDate() throws -> Date? {
        if completionDate == nil { guard details["completion_date_reference"] == .null else { throw CoreError("unsupported_reminder", "Inconsistent reminder completion witness") }; return nil }
        guard let text = details["completion_date_reference"].string, let bits = UInt64(text) else { throw CoreError("unsupported_reminder", "Exact reminder completion precision is unavailable") }
        let seconds = Double(bitPattern: bits)
        guard seconds.isFinite else { throw CoreError("unsupported_reminder", "Invalid reminder completion precision") }
        let date = Date(timeIntervalSinceReferenceDate: seconds)
        guard iso(date) == completionDate else { throw CoreError("unsupported_reminder", "Inconsistent reminder completion witness") }; return date
    }
    public var after: JSON { .object(["fields": fields.observedJSON, "completed": .bool(completed)]) }
    public func view(id: String, listID: String) throws -> JSON {
        if let completionDate { _ = try parseDate(completionDate) }
        let raw: JSON = .object(["native_id": .string(nativeID), "list_native_id": .string(listNativeID), "fields": fields.observedJSON, "completed": .bool(completed), "completion_date": .optional(completionDate), "details": details, "unsupported_reasons": .array(unsupportedReasons.map(JSON.string))])
        let value: JSON = .object(["id": .string(id), "list_id": .string(listID), "fields": fields.observedJSON, "completed": .bool(completed), "completion_date": .optional(completionDate), "details": details, "unsupported_reasons": .array(unsupportedReasons.map(JSON.string)), "fingerprint": .string(digest(try raw.data()))])
        guard try value.data().count <= 131072 else { throw CoreError("reminder_too_large", "Reminder snapshot exceeds bounded review size") }; return value
    }
}

public struct ReminderWriteResult {
    public let record: ReminderRecord?
    public let completionDate: Date?
    public init(record: ReminderRecord?, completionDate: Date?) { self.record = record; self.completionDate = completionDate }
}

public protocol ReminderBackend: AnyObject {
    func lists() throws -> [ReminderListRecord]
    func query(listID: String) throws -> [ReminderRecord]
    func get(nativeID: String, listID: String) throws -> ReminderRecord
    func apply(action: String, listID: String, existing: ReminderRecord?, fields: ReminderFields?, completed: Bool?, changedFields: [String], completionPolicy: String, completionDate: Date?, restoration: JSON?) throws -> ReminderWriteResult
}

public final class SyntheticReminderBackend: ReminderBackend {
    public var listRecords: [ReminderListRecord], records: [ReminderRecord]
    public private(set) var writeCount = 0
    var completionClock: () -> Date = Date.init
    public init(lists: [ReminderListRecord] = [ReminderListRecord(nativeID: "synthetic-reminders", title: "Synthetic reminders", source: "Synthetic")], reminders: [ReminderRecord] = []) { listRecords = lists; records = reminders }
    public func lists() throws -> [ReminderListRecord] { listRecords }
    public func query(listID: String) throws -> [ReminderRecord] { records.filter { $0.listNativeID == listID } }
    public func get(nativeID: String, listID: String) throws -> ReminderRecord {
        guard let result = records.first(where: { $0.nativeID == nativeID && $0.listNativeID == listID }) else { throw CoreError("reminder_missing", "Reminder no longer resolves; query again") }; return result
    }
    public func apply(action: String, listID: String, existing: ReminderRecord?, fields: ReminderFields?, completed: Bool?, changedFields: [String], completionPolicy: String, completionDate: Date?, restoration: JSON?) throws -> ReminderWriteResult {
        try ProviderMutationAttempt.run { attempt in
            guard listRecords.contains(where: { $0.nativeID == listID && $0.writable }) else { throw CoreError("read_only", "Reminder list is not writable") }
            if let existing { guard try get(nativeID: existing.nativeID, listID: listID) == existing else { throw CoreError("stale_event", "Reminder changed before provider entry") } }
            let chosen = completionPolicy == "set_on_commit" ? ReminderCompletionTime.onCommit(now: completionClock()) : completionDate
            return try attempt.mutate {
                writeCount += 1
                if action == "delete" { records.removeAll { $0.nativeID == existing?.nativeID && $0.listNativeID == listID }; return ReminderWriteResult(record: nil, completionDate: nil) }
                guard let fields, let completed else { throw CoreError("invalid_fields", "Missing reminder assignment") }
                var result = existing ?? ReminderRecord(nativeID: UUID().uuidString, listNativeID: listID, fields: fields.withoutAlerts)
                result.fields = fields.withoutAlerts; result.completed = completed; result.completionDate = chosen.map(iso)
                var details = (restoration?.object ?? result.details.object) ?? [:]
                if existing == nil || changedFields.contains("start") { details["start_components"] = restoration?["start_components"] ?? ReminderDate.rawComponents(fields.start?.components()) }
                if existing == nil || changedFields.contains("due") { details["due_components"] = restoration?["due_components"] ?? ReminderDate.rawComponents(fields.due?.components()) }
                details["completion_date_reference"] = chosen.map { .string(String($0.timeIntervalSinceReferenceDate.bitPattern)) } ?? .null
                if let alarms = restoration?["alarms"].array { details["alarms"] = .array(alarms) }
                else if let alerts = fields.alerts { details["alarms"] = .array(alerts.map(\.rawAlarm)) }
                result.details = .object(details)
                records.removeAll { $0.nativeID == result.nativeID && $0.listNativeID == listID }; records.append(result)
                return ReminderWriteResult(record: result, completionDate: chosen)
            }
        }
    }
}
