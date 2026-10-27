// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin
import XCTest
@testable import CalendarCore

/// XCTest-only fixture export. The production helper has no fault/seed control.
final class ReminderExportFixtureTests: XCTestCase {
    func testSyntheticUnknownFixtureCanBeExportedClosed() throws {
        let fm = FileManager.default, env = ProcessInfo.processInfo.environment
        let supplied = env["CALENDAR_MCP_REMINDER_EXPORT_ROOT"]
        let temporary = fm.temporaryDirectory.appendingPathComponent("reminders-export-test-" + UUID().uuidString)
        let root = supplied.map { URL(fileURLWithPath: $0) } ?? temporary.appendingPathComponent("native-synthetic")
        if supplied == nil { try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); addTeardownBlock { try? FileManager.default.removeItem(at: temporary) } }
        else {
            guard root.lastPathComponent == "native-synthetic", root.deletingLastPathComponent().lastPathComponent == "gateway",
                  root.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.hasPrefix("reminders-synthetic-export-") else { throw CoreError("invalid_configuration", "Export must target a fresh synthetic fixture tree") }
        }
        var info = stat()
        let parent = root.deletingLastPathComponent()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
              !fm.fileExists(atPath: root.path) else { throw CoreError("unsafe_state", "Export requires an owned private parent and absent fixture state") }
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let binding = env["CALENDAR_MCP_REMINDER_EXPORT_BINDING"] ?? String(repeating: "a", count: 64)
        guard binding.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CoreError("invalid_configuration", "Use a synthetic credential binding") }
        let kind = env["CALENDAR_MCP_REMINDER_EXPORT_TEXT"] ?? "bmp"
        let text: String
        switch kind { case "del": text = String(repeating: "\u{7f}", count: 30000)
        case "bmp": text = String(repeating: "中", count: 30000)
        case "nonbmp": text = String(repeating: "🗓", count: 14000)
        default: throw CoreError("invalid_configuration", "Unknown synthetic text fixture") }
        func seed() throws -> String {
            let state = try ReminderStateStore(directory: root.appendingPathComponent("reminders"), backendMode: "synthetic", credentialBinding: binding)
            let fields = try ReminderFields(.object(["title": .string("Synthetic export reminder"), "notes": .string(text), "priority": .int(0), "start": .null, "due": .null]), retained: true)
            let record = ReminderRecord(nativeID: "synthetic-export-reminder", listNativeID: "synthetic-reminders", fields: fields,
                details: .object(["start_components": .null, "due_components": .null, "completion_date_reference": .null,
                    "alarms": .array([]), "recurrence_rules": .array([]), "url": .null, "location": .null, "item_time_zone": .null, "attendees": .array([])]))
            let broker = ReminderBroker(state: state, backend: SyntheticReminderBackend(reminders: [record]))
            func call(_ name: String, _ args: JSON) throws -> JSON {
                let result = broker.handle(.object(["op": .string(name), "arguments": args]))
                guard result["error"] == .null else { throw CoreError("fixture_failed", "Synthetic fixture setup failed") }; return result["result"]
            }
            let list = try call("list_reminder_lists", .object([:]))["lists"].array![0]["id"].string!
            let id = try call("query_reminders", .object(["list_id": .string(list), "status": .string("all")]))["reminders"].array![0]["id"].string!
            let preview = try call("preflight_reminder_change", .object(["action": .string("modify"), "scope": .string("this"), "reminder_id": .string(id), "fields": .object(["title": .string("Changed synthetic export reminder")])]))["preview"]
            let nonce = preview["envelope"]["nonce"].string!
            _ = try state.claim(nonce: nonce, payload: preview["envelope"], now: Date())
            XCTAssertEqual(try state.execution(nonce)?.state, "intent_recorded")
            return nonce
        }
        let nonce = try seed() // Every owner/lock is closed before a helper may open it.
        func verifyClosedUnknown() throws {
            let state = try ReminderStateStore(directory: root.appendingPathComponent("reminders"), backendMode: "synthetic", credentialBinding: binding)
            XCTAssertEqual(try state.execution(nonce)?.state, "unknown")
            XCTAssertEqual(try state.rows("SELECT nonce FROM quota").count, 1)
            try state.verifyAudit()
        }
        try verifyClosedUnknown()
        if supplied != nil {
            let file = root.appendingPathComponent("synthetic-fixture.json")
            try JSON.object(["nonce": .string(nonce)]).data().write(to: file, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
