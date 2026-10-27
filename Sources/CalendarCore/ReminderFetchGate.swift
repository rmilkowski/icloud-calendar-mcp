// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// One bounded native fetch. A late callback cannot publish into a cancelled request.
public final class ReminderFetchGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var closed = false
    private var waiting = false
    private var result: Result<Value, Error>?
    public init() {}

    @discardableResult public func complete(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !closed else { lock.unlock(); return false }
        closed = true; self.result = result
        lock.unlock(); signal.signal(); return true
    }

    public func wait(timeout: TimeInterval = 10) throws -> Value {
        guard timeout.isFinite, timeout > 0, timeout <= 10 else { throw CoreError("invalid_configuration", "Reminder fetch timeout must be within ten seconds") }
        lock.lock()
        guard !waiting else { lock.unlock(); throw CoreError("invalid_configuration", "Reminder fetch has one result consumer") }
        waiting = true; lock.unlock()
        let outcome = signal.wait(timeout: .now() + timeout)
        lock.lock()
        if outcome == .timedOut { closed = true; result = nil; lock.unlock(); throw CoreError("reminder_fetch_timeout", "Reminder fetch timed out; no automatic retry") }
        let value = result; result = nil; lock.unlock()
        guard let value else { throw CoreError("reminder_fetch_failed", "Reminder fetch returned no result") }
        return try value.get()
    }
}
