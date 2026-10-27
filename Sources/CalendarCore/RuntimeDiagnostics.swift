// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Local transport handshake only, not a remote MCP tool. The live status provider
/// is never evaluated for synthetic mode; no Calendar backend/store is consulted.
public func nativeRuntimeStatus(backendMode: String, pid: Int, liveAuthorization: () -> (name: String, raw: Int)) throws -> JSON {
    guard ["eventkit", "synthetic"].contains(backendMode) else { throw CoreError("invalid_configuration", "Invalid backend mode") }
    if backendMode == "synthetic" {
        return .object(["backend_mode": .string(backendMode), "authorization_status": .string("not_applicable"), "authorization_status_raw": .null, "pid": .int(pid)])
    }
    let status = liveAuthorization()
    return .object(["backend_mode": .string(backendMode), "authorization_status": .string(status.name), "authorization_status_raw": .int(status.raw), "pid": .int(pid)])
}
