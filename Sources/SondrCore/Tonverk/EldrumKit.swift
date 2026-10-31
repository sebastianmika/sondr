import Foundation

/// A Tonverk drum kit mapping (`.eldrum`): one sample per Subtrack pad, no velocity layers or round robin.
public struct EldrumKit: Equatable, Sendable {
    public static let pitches = [60, 62, 64, 65, 67, 69, 71, 72]
    public static let maxNameLength = 21
    static let header = "# ELEKTRON DRUM SET MAPPING FORMAT"

    public var name: String
    /// Sample filename per pad, in `pitches` order. Nil leaves the pad out of the file.
    public var slots: [String?]
    /// True when parsing dropped layers or round-robin samples, so saving would lose data.
    public private(set) var lossy = false

    public init(name: String, slots: [String?] = Array(repeating: nil, count: 8)) {
        precondition(slots.count == EldrumKit.pitches.count, "an eldrum has exactly 8 slots")
        self.name = name
        self.slots = slots
    }

    /// The mapping text. `comment` becomes an extra `#` line below the header (the device may not accept it).
    public func render(comment: String? = nil) throws -> String {
        guard name.count <= EldrumKit.maxNameLength else { throw EldrumError.nameTooLong(name) }
        var lines = [EldrumKit.header]
        if let comment { lines.append("# \(comment)") }
        lines += ["version = 0", "name = \(Self.quote(name))"]
        for (pitch, sample) in zip(EldrumKit.pitches, slots) {
            guard let sample else { continue }
            lines += [
                "", "[[key-zones]]", "pitch = \(pitch)", "key-center = \(pitch).0", "",
                "[[key-zones.velocity-layers]]", "velocity = 0.49411765", "strategy = 'Forward'", "",
                "[[key-zones.velocity-layers.sample-slots]]", "sample = \(Self.quote(sample))",
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads the first sample of the first layer of each pad; anything beyond that sets `lossy`.
    public static func parse(_ text: String) throws -> EldrumKit {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == header else { throw EldrumError.notAnEldrum }
        var kit = EldrumKit(name: "")
        var pad: Int?
        var layers = 0
        for line in lines {
            if line == "[[key-zones]]" {
                pad = nil
                layers = 0
            } else if line == "[[key-zones.velocity-layers]]" {
                layers += 1
                if layers > 1 { kit.lossy = true }
            } else if let value = Self.value(of: "pitch", in: line) {
                guard let p = Int(value), let index = pitches.firstIndex(of: p) else {
                    throw EldrumError.unknownPitch(value)
                }
                pad = index
            } else if let value = Self.value(of: "sample", in: line), let pad {
                if kit.slots[pad] == nil { kit.slots[pad] = Self.unquote(value) } else { kit.lossy = true }
            } else if let value = Self.value(of: "name", in: line), pad == nil {
                kit.name = Self.unquote(value)
            }
        }
        return kit
    }

    private static func value(of key: String, in line: String) -> String? {
        let prefix = "\(key) = "
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }

    private static func quote(_ value: String) -> String {
        value.contains("'") ? "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\"" : "'\(value)'"
    }

    private static func unquote(_ value: String) -> String {
        String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
    }
}

public enum EldrumError: Error, LocalizedError, Equatable {
    case nameTooLong(String)
    case notAnEldrum
    case unknownPitch(String)

    public var errorDescription: String? {
        switch self {
        case .nameTooLong(let name): return "The kit name \"\(name)\" is longer than \(EldrumKit.maxNameLength) characters."
        case .notAnEldrum: return "This is not a Tonverk drum set mapping."
        case .unknownPitch(let pitch): return "Pad pitch \(pitch) is not one of the eight Tonverk drum pads."
        }
    }
}
