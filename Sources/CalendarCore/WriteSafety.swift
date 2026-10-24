import Foundation
import Darwin

/// A local operator policy, never an MCP argument or an approval mechanism.
struct WriteSafetyPolicy: Equatable {
    static let defaults = try! WriteSafetyPolicy(json: .object([
        "version": .int(1), "delete_hour": .int(50), "delete_day": .int(200),
        "destructive_hour": .int(100), "destructive_day": .int(500)
    ]))
    let deleteHour: Int, deleteDay: Int, destructiveHour: Int, destructiveDay: Int
    init(json: JSON) throws {
        let keys: Set<String> = ["version", "delete_hour", "delete_day", "destructive_hour", "destructive_day"]
        guard let object = json.object, Set(object.keys) == keys, object["version"] == .int(1),
              let dh = object["delete_hour"]?.integer, let dd = object["delete_day"]?.integer,
              let wh = object["destructive_hour"]?.integer, let wd = object["destructive_day"]?.integer,
              [dh, dd, wh, wd].allSatisfy({ (1...100_000).contains($0) }), dd >= dh, wd >= wh, wh >= dh, wd >= dd else {
            throw CoreError("write_safety_configuration", "Invalid local write-safety.json; use version 1 and complete integer limits (1...100000), with day >= hour and destructive >= delete")
        }
        deleteHour = dh; deleteDay = dd; destructiveHour = wh; destructiveDay = wd
    }
    var json: JSON { .object(["version": .int(1), "delete_hour": .int(deleteHour), "delete_day": .int(deleteDay), "destructive_hour": .int(destructiveHour), "destructive_day": .int(destructiveDay)]) }

    static func read(directory: URL) throws -> WriteSafetyPolicy? {
        let path = directory.appendingPathComponent("write-safety.json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw CoreError("write_safety_configuration", "Cannot safely read local write-safety.json; repair its ownership, permissions or file type")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 16_384 else {
            throw CoreError("write_safety_configuration", "Local write-safety.json must be a single-link regular file owned by this user, mode 0600, at most 16 KiB")
        }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw CoreError("write_safety_configuration", "Cannot read local write-safety.json") }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= 16_384 else { throw CoreError("write_safety_configuration", "Local write-safety.json exceeds 16 KiB") }
        }
        do { return try WriteSafetyPolicy(json: JSON.parse(data)) }
        catch { throw CoreError("write_safety_configuration", "Invalid local write-safety.json; repair the complete strict version 1 policy before writing") }
    }
}
