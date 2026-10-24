import Foundation

/// A displayed exact review is invalidated by every inspection or selection change.
/// Generation checks also reject asynchronous results from an older UI request.
public struct NativeReviewGate {
    public private(set) var generation = 0
    private var reviewed: Int?
    public init() {}
    public mutating func invalidate() { generation += 1; reviewed = nil }
    @discardableResult public mutating func displayReview(generation expected: Int) -> Bool {
        guard expected == generation else { return false }; reviewed = expected; return true
    }
    public var canApply: Bool { reviewed == generation }
}

public func localRecoverySocketDirectory(stateDirectory: URL) throws -> URL {
    guard let resolved = realpath(stateDirectory.path, nil) else { throw CoreError("unsafe_state", "Cannot canonicalize local UI state directory") }
    defer { free(resolved) }
    let canonical = String(cString: resolved)
    return URL(fileURLWithPath: "/private/tmp/calendar-mcp-ui-\(getuid())-" + String(digest(Data(canonical.utf8)).prefix(20)), isDirectory: true)
}
