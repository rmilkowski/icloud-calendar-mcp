import Foundation

/// Alarm order is provider-owned. Compare the complete objects as a multiset;
/// every key, exact value and duplicate remains part of the event snapshot.
public enum EventSnapshot {
    public static func canonicalAlarms(_ value: JSON) throws -> JSON {
        guard let alarms = value.array, alarms.allSatisfy({ $0.object != nil }) else {
            throw CoreError("invalid_snapshot", "Alarm snapshots must contain complete objects")
        }
        let keyed = try alarms.map { (try $0.data(), $0) }
        return .array(keyed.sorted { $0.0.lexicographicallyPrecedes($1.0) }.map(\.1))
    }

    public static func canonicalDetails(_ value: JSON) throws -> JSON {
        guard var details = value.object else { throw CoreError("invalid_snapshot", "Event details must be an object") }
        if let alarms = details["alarms"], alarms != .null { details["alarms"] = try canonicalAlarms(alarms) }
        return .object(details)
    }

    public static func alarmsEquivalent(_ left: JSON, _ right: JSON) -> Bool {
        if left == .null || right == .null { return left == .null && right == .null }
        do { return try canonicalAlarms(left) == canonicalAlarms(right) } catch { return false }
    }

    public static func detailsEquivalent(_ left: JSON, _ right: JSON) -> Bool {
        do { return try canonicalDetails(left) == canonicalDetails(right) } catch { return false }
    }

    private static func comparisonView(_ value: JSON) throws -> JSON? {
        guard var body = value.object, let fingerprint = body.removeValue(forKey: "fingerprint")?.string,
              fingerprint == digest(try JSON.object(body).data()), let details = body["details"] else { return nil }
        body["details"] = try canonicalDetails(details)
        body["fingerprint"] = .string(digest(try JSON.object(body).data()))
        return .object(body)
    }

    /// Call only after original preview authentication or authoritative history reads.
    /// Original fingerprints are verified before creating temporary comparison views.
    /// The caller's authenticated envelope and retained execution are never changed.
    public static func equivalent(_ left: JSON, _ right: JSON) -> Bool {
        if left == .null || right == .null { return left == .null && right == .null }
        do {
            guard let a = try comparisonView(left), let b = try comparisonView(right) else { return false }
            return a == b
        } catch { return false }
    }

    static func seriesReferenceEquivalent(_ left: JSON, _ right: JSON) -> Bool {
        guard var a = left.object, var b = right.object,
              let selectedA = a.removeValue(forKey: "selected"), let selectedB = b.removeValue(forKey: "selected") else { return false }
        return a == b && equivalent(selectedA, selectedB)
    }

    static func futureReferenceEquivalent(_ left: JSON, _ right: JSON) -> Bool {
        guard var a = left.object, var b = right.object,
              let anchorA = a.removeValue(forKey: "first_anchor"), let anchorB = b.removeValue(forKey: "first_anchor") else { return false }
        return a == b && equivalent(anchorA, anchorB)
    }

    static func terminationReferenceEquivalent(_ left: JSON, _ right: JSON) -> Bool {
        guard var a = left.object, var b = right.object,
              let anchorA = a.removeValue(forKey: "first_anchor"), let anchorB = b.removeValue(forKey: "first_anchor"),
              let referenceA = a.removeValue(forKey: "reference"), let referenceB = b.removeValue(forKey: "reference") else { return false }
        return a == b && equivalent(anchorA, anchorB) && equivalent(referenceA, referenceB)
    }

    private static func comparisonRollback(_ value: JSON) throws -> JSON {
        guard var rollback = value.object else { throw CoreError("invalid_snapshot", "Rollback metadata must be an object") }
        if let alarms = rollback["alarm_restoration"], alarms != .null { rollback["alarm_restoration"] = try canonicalAlarms(alarms) }
        if let restoration = rollback["restoration"], restoration != .null {
            guard var restored = restoration.object, let details = restored["details"] else { throw CoreError("invalid_snapshot", "Restoration details are unavailable") }
            restored["details"] = try canonicalDetails(details)
            rollback["restoration"] = .object(restored)
        }
        return .object(rollback)
    }

    static func rollbackMetadataEquivalent(_ left: JSON, _ right: JSON) -> Bool {
        do { return try comparisonRollback(left) == comparisonRollback(right) } catch { return false }
    }
}
