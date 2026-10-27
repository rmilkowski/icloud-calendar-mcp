// SPDX-FileCopyrightText: 2026 Robert Milkowski
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct CoreError: Error, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { message }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

/// Integer-only JSON is sufficient for the public protocol. Canonical signing never
/// depends on Foundation's floating-point formatting or dictionary iteration order.
public enum JSON: Codable, Equatable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), int(Int), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: JSON]? { if case .object(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var array: [JSON]? { if case .array(let v) = self { v } else { nil } }
    public var boolean: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var integer: Int? { if case .int(let v) = self { v } else { nil } }
    public subscript(_ key: String) -> JSON { object?[key] ?? .null }
    public static func optional(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }
    public func data() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
    public func text() throws -> String { String(decoding: try data(), as: UTF8.self) }
    public static func parse(_ data: Data) throws -> JSON {
        guard data.count <= 524_288 else { throw CoreError("request_too_large", "Native request exceeds 512 KiB") }
        // Reject duplicate object keys, which otherwise have parser-dependent meaning.
        var parser = StrictJSON(data: Array(data)); return try parser.parse()
    }
}

private struct StrictJSON {
    let data: [UInt8]
    var index = 0
    mutating func parse() throws -> JSON {
        let value = try value(depth: 0); space()
        guard index == data.count else { throw bad() }; return value
    }
    func bad() -> CoreError { CoreError("invalid_arguments", "Expected bounded JSON with unique keys and integer numbers") }
    mutating func space() { while index < data.count && [9, 10, 13, 32].contains(data[index]) { index += 1 } }
    mutating func consume(_ byte: UInt8) -> Bool {
        space(); if index < data.count && data[index] == byte { index += 1; return true }; return false
    }
    mutating func string() throws -> String {
        space(); let start = index
        guard consume(34) else { throw bad() }
        while index < data.count {
            let byte = data[index]; index += 1
            if byte == 92 { guard index < data.count else { throw bad() }; index += 1 }
            else if byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(data[start..<index]))
            } else if byte < 32 { throw bad() }
        }
        throw bad()
    }
    mutating func value(depth: Int) throws -> JSON {
        guard depth <= 24 else { throw bad() }; space()
        guard index < data.count else { throw bad() }
        if data[index] == 34 { return .string(try string()) }
        if consume(123) {
            var object: [String: JSON] = [:]
            if consume(125) { return .object(object) }
            repeat {
                let key = try string()
                guard object[key] == nil, consume(58) else { throw bad() }
                object[key] = try value(depth: depth + 1)
                if consume(125) { return .object(object) }
            } while consume(44)
            throw bad()
        }
        if consume(91) {
            var values: [JSON] = []
            if consume(93) { return .array(values) }
            repeat {
                values.append(try value(depth: depth + 1))
                if consume(93) { return .array(values) }
            } while consume(44)
            throw bad()
        }
        for (word, result) in [("true", JSON.bool(true)), ("false", .bool(false)), ("null", .null)] {
            let bytes = Array(word.utf8)
            if data[index...].starts(with: bytes) { index += bytes.count; return result }
        }
        let start = index
        if data[index] == 45 { index += 1 }
        guard index < data.count, (48...57).contains(data[index]) else { throw bad() }
        if data[index] == 48 { index += 1 }
        else { while index < data.count && (48...57).contains(data[index]) { index += 1 } }
        guard let number = Int(String(decoding: data[start..<index], as: UTF8.self)) else { throw bad() }
        return .int(number)
    }
}

public struct Arguments {
    public let values: [String: JSON]
    public init(_ json: JSON, allowed: Set<String>, required: Set<String> = []) throws {
        guard let object = json.object, Set(object.keys).isSubset(of: allowed), required.isSubset(of: Set(object.keys)) else {
            throw CoreError("invalid_arguments", "Missing or unknown argument")
        }; values = object
    }
    public func string(_ key: String) throws -> String {
        guard let value = values[key]?.string, !value.isEmpty, value.count <= 10_000 else {
            throw CoreError("invalid_arguments", "Invalid string argument: \(key)")
        }; return value
    }
}
