// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import EventKit
import AppKit
import CalendarCore
import Darwin

func output(_ value: JSON) {
    if let data = try? value.data() { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
}
func errorJSON(_ error: any Error) -> JSON {
    let e = error as? CoreError ?? CoreError("native_error", "Native operation failed")
    return .object(["error": .object(["code": .string(e.code), "message": .string(e.message)])])
}
func flag(_ name: String, _ arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }; return arguments[index + 1]
}
func runtimeStatus(_ mode: String) throws -> JSON {
    try nativeRuntimeStatus(backendMode: mode, pid: Int(getpid())) {
        let status = EKEventStore.authorizationStatus(for: .event)
        let name: String
        switch status {
        case .notDetermined: name = "not_determined"
        case .restricted: name = "restricted"
        case .denied: name = "denied"
        case .fullAccess: name = "full_access"
        case .writeOnly: name = "write_only"
        @unknown default: name = "unknown"
        }
        return (name, status.rawValue)
    }
}

func runNativeInput(broker: Broker, mode: String) throws {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            // Foundation read(upToCount:) can wait for a full pipe buffer. The POSIX
            // read returns available bytes, which keeps resident NDJSON interactive.
            let count = Darwin.read(STDIN_FILENO, &bytes, 16_384)
            if count < 0 { if errno == EINTR { continue }; throw CoreError("input_failed", "Native input read failed") }
            if count == 0 { if !buffer.isEmpty { output(errorJSON(CoreError("invalid_arguments", "Native requests must end with newline"))) }; break }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                do {
                    let request = try JSON.parse(line)
                    if request["op"].string == "authorization_status" {
                        let envelope = try Arguments(request, allowed: ["op", "arguments"], required: ["op", "arguments"])
                        _ = try Arguments(envelope.values["arguments"]!, allowed: [])
                        output(.object(["result": try runtimeStatus(mode)]))
                    } else { output(broker.handle(request)) }
                } catch { output(errorJSON(error)) }
            }
            if buffer.count > 524_288 { output(errorJSON(CoreError("request_too_large", "Native request exceeds 512 KiB"))); exit(1) }

        }
}
@MainActor func runNativeApplication() { NSApplication.shared.run() }

let args = Array(CommandLine.arguments.dropFirst())
do {
    if args == ["--status"] {
        output(.object(["result": try runtimeStatus("eventkit")]))
    } else if args == ["--authorize"] {
        // This is the only authorization request in the executable. Never called by serve.
        let store = EKEventStore()
        do {
            let allowed = try await store.requestFullAccessToEvents()
            withExtendedLifetime(store) {
                output(.object(["result": .object(["full_access": .bool(allowed)])]))
            }
        } catch {
            withExtendedLifetime(store) {
                output(localAuthorizationFailure(
                    error,
                    status: EKEventStore.authorizationStatus(for: .event).rawValue,
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    usageDescriptionPresent: (Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") as? String)?.isEmpty == false
                ))
            }
            exit(1)
        }
    } else if args.first == "--serve" {
        let allowed: Set<String> = ["--state-dir", "--backend", "--credential-binding", "--lifetime-fifo"]
        guard [7, 9].contains(args.count), stride(from: 1, to: args.count, by: 2).allSatisfy({ allowed.contains(args[$0]) }), Set(stride(from: 1, to: args.count, by: 2).map { args[$0] }).count == (args.count - 1) / 2,
              let statePath = flag("--state-dir", args), statePath.hasPrefix("/"),
              let mode = flag("--backend", args), ["eventkit", "synthetic"].contains(mode), let binding = flag("--credential-binding", args) else { throw CoreError("invalid_configuration", "Serve requires --state-dir absolute-path --backend eventkit|synthetic --credential-binding SHA256") }
        if let path = flag("--lifetime-fifo", args) {
            let lifetime = try LauncherLifetime(path: path)
            guard lifetime.launcherIsAlive() else { _exit(70) }
            // The queue retains the observer until process exit, before state opens.
            DispatchQueue.global(qos: .utility).async { lifetime.monitorUntilLauncherDisappears() }
        }
        let state = try StateStore(directory: URL(fileURLWithPath: statePath))
        try state.configure(backendMode: mode, credentialBinding: binding)
        let backend: any CalendarBackend = mode == "synthetic" ? SyntheticBackend() : EventKitBackend()
        let broker = Broker(state: state, backend: backend)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let recoveryWindow = LocalRecoveryWindow(broker: broker)
        // The open-only window is optional; a failed local listener must not stop
        // the authenticated broker or weaken the native Apply review gate.
        let recoverySocket = try? LocalRecoverySocket(directory: state.directory) { recoveryWindow.open() }
        broker.setLocalRecoveryUIAvailable(recoverySocket != nil)
        let maintenance = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        maintenance.schedule(deadline: .now() + 60, repeating: 60)
        maintenance.setEventHandler { _ = broker.maintainRecoveryDetails() }; maintenance.resume()
        DispatchQueue.global(qos: .userInitiated).async {
            do { try runNativeInput(broker: broker, mode: mode); exit(0) }
            catch { output(errorJSON(error)); exit(1) }
        }
        withExtendedLifetime((recoverySocket, maintenance, recoveryWindow)) { runNativeApplication() }
    } else if args.first == "--migrate-recovery", args.count == 3, let path = flag("--state-dir", args), path.hasPrefix("/") {
        let state = try StateStore(directory: URL(fileURLWithPath: path))
        try state.verifyAudit()
        output(.object(["result": try state.recoveryMetadata()]))
    } else if args.first == "--rotate-keys", args.count == 3, let path = flag("--state-dir", args) {
        let state = try StateStore(directory: URL(fileURLWithPath: path)); try state.rotateCredentials()
        output(.object(["result": .object(["rotated": .bool(true)])]))
    } else if args.first == "--reconcile", args.count == 9, let path = flag("--state-dir", args), let nonce = flag("--nonce", args), let outcome = flag("--outcome", args), let evidence = flag("--evidence", args), isatty(STDIN_FILENO) == 1 {
        let state = try StateStore(directory: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("Exceptional recovery only. Confirm external inspection by typing: reconcile \(nonce)\n".utf8))
        guard readLine() == "reconcile \(nonce)" else { throw CoreError("reconciliation_cancelled", "Reconciliation not confirmed") }
        output(.object(["result": try state.reconcile(nonce: nonce, outcome: outcome, evidence: evidence)]))
    } else { throw CoreError("invalid_configuration", "Use --status, --authorize, --serve, --migrate-recovery, --rotate-keys or exceptional local --reconcile; no direct apply interface exists") }
} catch { output(errorJSON(error)); exit(1) }
