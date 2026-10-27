// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Public write intent. Event snapshots retain their original rich alarm format.
public struct EventAlert: Equatable, Sendable {
    public let relativeMinutes: Int?
    public let at: String?
    public init(json: JSON) throws {
        let a = try Arguments(json, allowed: ["relative_minutes", "at"])
        guard a.values.count == 1 else { throw CoreError("invalid_alerts", "An alert needs exactly one trigger") }
        if let value = a.values["relative_minutes"] {
            guard let minutes = value.integer, (-525600...525600).contains(minutes) else { throw CoreError("invalid_alerts", "Relative alert minutes must be an integer from -525600 through 525600") }
            relativeMinutes = minutes; at = nil
        } else {
            guard let value = a.values["at"]?.string else { throw CoreError("invalid_alerts", "Absolute alerts need an explicit-offset timestamp") }
            relativeMinutes = nil; at = iso(try parseDate(value))
        }
    }
    public var json: JSON { relativeMinutes.map { .object(["relative_minutes": .int($0)]) } ?? .object(["at": .string(at!)]) }
    public var rawAlarm: JSON { .object(["absolute_date": .optional(at), "relative_offset": .string(String(Double(relativeMinutes ?? 0) * 60)), "proximity": .int(0), "structured_location": .null, "type": .int(0), "email_address": .null, "sound_name": .null]) }
    public static func parse(_ json: JSON) throws -> [EventAlert] {
        guard let values = json.array, values.count <= 10 else { throw CoreError("invalid_alerts", "Use an array of at most ten alerts") }
        let alerts = try values.map(EventAlert.init(json:))
        let keys = try alerts.map { try $0.json.text() }
        guard Set(keys).count == keys.count else { throw CoreError("invalid_alerts", "Duplicate alert triggers are unsupported") }
        return zip(keys, alerts).sorted { $0.0 < $1.0 }.map(\.1)
    }
    /// Canonical semantic read-back of a complete plain-display alarm replacement.
    public static func matches(_ alerts: [EventAlert], raw: JSON) throws -> Bool {
        do { return try matchesObserved(alerts, raw: raw) } catch { return false }
    }
    private static func matchesObserved(_ alerts: [EventAlert], raw: JSON) throws -> Bool {
        guard let alarms = raw.array, alarms.count == alerts.count else { return false }
        var observed: [EventAlert] = []
        for alarm in alarms {
            guard alarm["type"] == .int(0), alarm["proximity"] == .int(0), alarm["structured_location"] == .null,
                  alarm["email_address"] == .null, alarm["sound_name"] == .null else { return false }
            if let absolute = alarm["absolute_date"].string {
                observed.append(try EventAlert(json: .object(["at": .string(absolute)])))
            } else {
                guard alarm["absolute_date"] == .null, let seconds = alarm["relative_offset"].string.flatMap(Double.init), seconds.isFinite,
                      seconds.truncatingRemainder(dividingBy: 60) == 0, abs(seconds) <= 525600 * 60 else { return false }
                observed.append(try EventAlert(json: .object(["relative_minutes": .int(Int(seconds / 60))])))
            }
        }
        return try parse(.array(observed.map(\.json))) == alerts
    }
}
