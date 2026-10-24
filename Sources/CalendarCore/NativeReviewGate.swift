import Foundation
import Darwin

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

/// The OS user-temp directory is protected before deriving any predictable child.
/// TMPDIR and the legacy shared /private/tmp name are never trusted.
public func localRecoveryTemporaryBase() throws -> URL {
    let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
    guard size > 1, size <= 4096 else { throw CoreError("local_ui_unavailable", "Cannot locate protected user temporary directory") }
    var bytes = [CChar](repeating: 0, count: size)
    guard confstr(_CS_DARWIN_USER_TEMP_DIR, &bytes, size) == size,
          let path = String(bytes: bytes.dropLast().map { UInt8(bitPattern: $0) }, encoding: .utf8), path.hasPrefix("/") else {
        throw CoreError("local_ui_unavailable", "Invalid user temporary directory")
    }
    return try validatedLocalRecoveryTemporaryBase(URL(fileURLWithPath: path, isDirectory: true))
}

public func validatedLocalRecoveryTemporaryBase(_ directory: URL) throws -> URL {
    // Inspect the supplied leaf before canonicalization so a symlink cannot hide.
    try validateLocalRecoveryDirectory(directory, exactMode: false)
    guard let resolved = realpath(directory.path, nil) else { throw CoreError("unsafe_state", "Cannot canonicalize local UI temporary directory") }
    defer { free(resolved) }
    let canonical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    try validateLocalRecoveryDirectory(canonical, exactMode: false)
    return canonical
}

public func validateLocalRecoveryDirectory(_ directory: URL, exactMode: Bool = true) throws {
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0,
          !exactMode || info.st_mode & 0o777 == 0o700 else {
        throw CoreError("unsafe_state", "Local UI directory must be private, user-owned and not a symlink")
    }
}

public func localRecoverySocketDirectory(stateDirectory: URL) throws -> URL {
    guard let resolved = realpath(stateDirectory.path, nil) else { throw CoreError("unsafe_state", "Cannot canonicalize local UI state directory") }
    defer { free(resolved) }
    let canonical = String(cString: resolved)
    let base = try localRecoveryTemporaryBase()
    let directory = base.appendingPathComponent("cmui-" + String(digest(Data(canonical.utf8)).prefix(20)), isDirectory: true)
    guard directory.appendingPathComponent("s").path.utf8.count < 104 else { throw CoreError("local_ui_unavailable", "Protected temporary path is too long for local UI socket") }
    return directory
}

/// Cleanup only the socket inode this listener actually bound, never a replacement.
public struct LocalRecoverySocketIdentity {
    private let device: dev_t
    private let inode: ino_t
    public init(path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw CoreError("unsafe_state", "Unsafe local UI socket") }
        device = info.st_dev; inode = info.st_ino
    }
    public func removeIfUnchanged(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_dev == device, info.st_ino == inode else { return }
        _ = unlink(path)
    }
}
