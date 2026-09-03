import Foundation

public struct TaskID: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) throws {
        let input = rawValue.utf8
        guard input.count == 26 else {
            throw OTodoError.validation(
                field: "taskID",
                message: "Expected a 26-character Crockford Base32 ULID"
            )
        }

        var normalized = [UInt8]()
        normalized.reserveCapacity(26)
        for byte in input {
            let uppercaseByte = (97 ... 122).contains(byte) ? byte - 32 : byte
            guard Self.isCrockfordDigit(uppercaseByte) else {
                throw OTodoError.validation(
                    field: "taskID",
                    message: "Expected a 26-character Crockford Base32 ULID"
                )
            }
            normalized.append(uppercaseByte)
        }

        guard let first = normalized.first,
              first >= 48,
              first <= 55
        else {
            throw OTodoError.validation(
                field: "taskID",
                message: "Expected a 26-character Crockford Base32 ULID"
            )
        }

        self.rawValue = String(decoding: normalized, as: UTF8.self)
    }

    private static func isCrockfordDigit(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte)
            || (65 ... 72).contains(byte)
            || (74 ... 75).contains(byte)
            || (77 ... 78).contains(byte)
            || (80 ... 84).contains(byte)
            || (86 ... 90).contains(byte)
    }

    public var description: String { rawValue }

    public static func < (lhs: TaskID, rhs: TaskID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Generates standards-compliant ULIDs from the current Unix millisecond and
/// 80 bits supplied by Swift's system random number generator.
public struct ULIDGenerator: Sendable, ULIDGenerating {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    private static let millisecondLimit: UInt64 = 1 << 48

    public init() {}

    public func generate(at date: Date = Date()) throws -> TaskID {
        let milliseconds = floor(date.timeIntervalSince1970 * 1_000)
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds < Double(Self.millisecondLimit)
        else {
            throw OTodoError.validation(
                field: "timestamp",
                message: "ULID timestamps must fit in unsigned 48-bit Unix milliseconds"
            )
        }

        var random = SystemRandomNumberGenerator()
        let randomnessHigh = UInt16.random(in: .min ... .max, using: &random)
        let randomnessLow = UInt64.random(in: .min ... .max, using: &random)

        return try TaskID(rawValue: Self.encode(
            milliseconds: UInt64(milliseconds),
            randomnessHigh: randomnessHigh,
            randomnessLow: randomnessLow
        ))
    }

    private static func encode(
        milliseconds: UInt64,
        randomnessHigh: UInt16,
        randomnessLow: UInt64
    ) -> String {
        var encoded = [UInt8](repeating: alphabet[0], count: 26)
        var timestamp = milliseconds
        for index in stride(from: 9, through: 0, by: -1) {
            encoded[index] = alphabet[Int(timestamp & 0x1f)]
            timestamp >>= 5
        }

        var low = randomnessLow
        for index in stride(from: 25, through: 14, by: -1) {
            encoded[index] = alphabet[Int(low & 0x1f)]
            low >>= 5
        }

        var high = (UInt32(randomnessHigh) << 4) | UInt32(low)
        for index in stride(from: 13, through: 10, by: -1) {
            encoded[index] = alphabet[Int(high & 0x1f)]
            high >>= 5
        }

        return String(decoding: encoded, as: UTF8.self)
    }
}
