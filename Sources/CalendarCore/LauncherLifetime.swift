// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

/// A local capability shared only with the launcher. The launcher keeps the sole
/// writer open without sending data; its death/close is observed independently of
/// a blocked protocol read or EventKit call. No calendar API is used here.
public final class LauncherLifetime: @unchecked Sendable {
    private let descriptor: Int32
    public init(path: String) throws {
        guard path.hasPrefix("/") else { throw CoreError("unsafe_lifetime_fifo", "Lifetime FIFO path must be absolute") }
        let url = URL(fileURLWithPath: path)
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CoreError("unsafe_lifetime_fifo", "Cannot open private lifetime directory") }
        defer { close(parent) }
        var directoryInfo = stat()
        guard fstat(parent, &directoryInfo) == 0, directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o7777 == 0o700 else {
            throw CoreError("unsafe_lifetime_fifo", "Lifetime directory must be owned by the current user with mode 0700")
        }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CoreError("unsafe_lifetime_fifo", "Cannot open lifetime FIFO") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFIFO, info.st_mode & 0o7777 == 0o600 else {
            close(fd); throw CoreError("unsafe_lifetime_fifo", "Lifetime endpoint must be an owned FIFO with mode 0600")
        }
        descriptor = fd
    }
    deinit { close(descriptor) }
    /// True only while the writer is still present and has sent no bytes.
    public func launcherIsAlive() -> Bool {
        var byte: UInt8 = 0
        let count = read(descriptor, &byte, 1)
        return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
    }
    public func monitorUntilLauncherDisappears() -> Never {
        while true {
            if !launcherIsAlive() { _exit(70) }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let result = poll(&item, 1, 250)
            if result < 0 && errno != EINTR { _exit(70) }
            if item.revents & Int16(POLLNVAL) != 0 { _exit(70) }
        }
    }
}
