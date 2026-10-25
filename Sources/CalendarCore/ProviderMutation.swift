import Foundation

public enum WriteFailureStage: String, Sendable {
    case providerPreflight = "provider_preflight", providerMutation = "provider_mutation"
    case providerRefresh = "provider_refresh", providerPrefixRead = "provider_prefix_read"
    case boundaryAbsence = "boundary_absence", prefixVerification = "prefix_verification"
    case resultVerification = "result_verification", outcomePersistence = "outcome_persistence"
}

/// Closed diagnostics never retain provider messages, NSError userInfo or event data.
struct WriteDiagnostic: Sendable {
    static let codes: Set<String> = ["calendar_access_required", "calendar_missing", "event_missing", "identity_ambiguous", "stale_event", "stale_calendar", "stale_rollback", "read_only", "invalid_fields", "invalid_timezone", "stale_timezone", "unsupported_scope", "unsupported_restore", "unsupported_recurrence", "unsupported_all_day", "future_boundary_elapsed", "verification_failed", "audit_unavailable", "internal_error", "provider_error"]
    let stage: WriteFailureStage
    let code: String
    init(stage: WriteFailureStage, error: Error) {
        self.stage = stage
        if let failure = error as? ProviderMutationFailure { code = failure.diagnostic.code }
        else if let core = error as? CoreError { code = Self.codes.contains(core.code) ? core.code : "internal_error" }
        else { code = "provider_error" }
    }
    var json: JSON { .object(["version": .int(1), "stage": .string(stage.rawValue), "code": .string(code)]) }
    static func valid(_ value: JSON, preEntryOnly: Bool = false) -> Bool {
        guard let object = value.object, Set(object.keys) == ["version", "stage", "code"], value["version"] == .int(1),
              let raw = value["stage"].string, let stage = WriteFailureStage(rawValue: raw),
              let code = value["code"].string, codes.contains(code) else { return false }
        return !preEntryOnly || stage == .providerPreflight
    }
}

/// Only the native leaf attempt can construct this error; request JSON is never proof.
public struct ProviderMutationFailure: Error, Sendable {
    let enteredMutation: Bool
    let diagnostic: WriteDiagnostic
    fileprivate init(enteredMutation: Bool, diagnostic: WriteDiagnostic) { self.enteredMutation = enteredMutation; self.diagnostic = diagnostic }
    var provesNotEntered: Bool { !enteredMutation && diagnostic.stage == .providerPreflight }
}

/// One instance per leaf provider mutation. Entry is monotonic and precedes the API call.
public final class ProviderMutationAttempt {
    private var enteredMutation = false
    private var stage: WriteFailureStage = .providerPreflight
    private init() {}
    public func mutate<T>(_ operation: () throws -> T) throws -> T {
        enteredMutation = true; stage = .providerMutation
        return try operation()
    }
    public func reading(_ stage: WriteFailureStage) { self.stage = stage }
    public static func run<T>(_ operation: (ProviderMutationAttempt) throws -> T) throws -> T {
        let attempt = ProviderMutationAttempt()
        do {
            let result = try operation(attempt)
            guard attempt.enteredMutation else { throw CoreError("internal_error", "Provider returned without entering its mutation") }
            return result
        } catch {
            if let nested = error as? ProviderMutationFailure {
                throw ProviderMutationFailure(enteredMutation: attempt.enteredMutation || nested.enteredMutation, diagnostic: nested.diagnostic)
            }
            throw ProviderMutationFailure(enteredMutation: attempt.enteredMutation, diagnostic: WriteDiagnostic(stage: attempt.stage, error: error))
        }
    }
}

/// This wrapper is created only around the mutating backend call, never readback.
private struct UnenteredProviderCall: Error { let failure: ProviderMutationFailure }

extension Broker {
    func providerMutation<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let failure as ProviderMutationFailure where failure.provesNotEntered { throw UnenteredProviderCall(failure: failure) }
    }
    func writeFailure(_ error: Error, nonce: String, action: String, sequence: Int, stage: WriteFailureStage) -> JSON {
        if let proof = error as? UnenteredProviderCall {
            do { return try state.finishNotApplied(nonce: nonce, action: action, failure: proof.failure, sequence: sequence) }
            catch { return unknownWrite(error, nonce: nonce, action: action, sequence: sequence, stage: .outcomePersistence) }
        }
        return unknownWrite(error, nonce: nonce, action: action, sequence: sequence, stage: stage)
    }
    func unknownWrite(_ error: Error, nonce: String, action: String, sequence: Int, stage: WriteFailureStage) -> JSON {
        let diagnostic: WriteDiagnostic
        if let failure = error as? ProviderMutationFailure, failure.enteredMutation { diagnostic = failure.diagnostic }
        else { diagnostic = WriteDiagnostic(stage: stage, error: error) }
        let result: JSON = .object(["nonce": .string(nonce), "state": .string("unknown"), "action": .string(action), "audit_sequence": .int(sequence), "diagnostic": diagnostic.json, "message": .string("Write outcome is unknown. Do not retry Calendar writes; inspect the original change status before related changes")])
        try? state.finish(nonce: nonce, state: "unknown", result: result, event: "write_unknown")
        return result
    }
}
