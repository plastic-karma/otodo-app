import Foundation

/// A safe, data-only YAML value. Mappings are arrays so source property order is retained.
public indirect enum YAMLValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case sequence([YAMLValue])
    case mapping([YAMLProperty])

    private enum Kind: String, Codable {
        case null
        case bool
        case integer
        case double
        case string
        case sequence
        case mapping
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .null:
            self = .null
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case .double:
            let value = try container.decode(Double.self, forKey: .value)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "YAML floating-point values must be finite"
                )
            }
            self = .double(value)
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .sequence:
            self = .sequence(try container.decode([YAMLValue].self, forKey: .value))
        case .mapping:
            self = .mapping(try container.decode([YAMLProperty].self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode(Kind.null, forKey: .kind)
        case let .bool(value):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .double(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "YAML floating-point values must be finite"
                    )
                )
            }
            try container.encode(Kind.double, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .string(value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .sequence(value):
            try container.encode(Kind.sequence, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .mapping(value):
            try container.encode(Kind.mapping, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct YAMLProperty: Sendable, Equatable, Codable {
    public let name: String
    public let value: YAMLValue

    public init(name: String, value: YAMLValue) {
        self.name = name
        self.value = value
    }
}
