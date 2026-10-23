import Foundation

/// Explicit local --authorize diagnostics only. Never used for MCP responses or
/// general error handling: NSError userInfo and underlying errors are not emitted.
public func localAuthorizationFailure(_ error: any Error, status: Int, bundleIdentifier: String?, usageDescriptionPresent: Bool) -> JSON {
    let native = error as NSError
    func clean(_ text: String, limit: Int) -> String {
        let filtered = text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        return String(filtered.prefix(limit))
    }
    return .object(["error": .object([
        "code": .string("calendar_authorization_failed"),
        "message": .string(clean(native.localizedDescription, limit: 1024)),
        "ns_error_domain": .string(clean(native.domain, limit: 256)),
        "ns_error_code": .int(native.code),
        "authorization_status_raw": .int(status),
        "bundle_identifier": bundleIdentifier.map { .string(clean($0, limit: 256)) } ?? .null,
        "usage_description_present": .bool(usageDescriptionPresent)
    ])])
}
