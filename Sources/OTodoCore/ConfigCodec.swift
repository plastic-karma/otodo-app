import Foundation

public struct StrictStoreConfigCodec: StoreConfigCoding, Sendable {
    public static let maximumConfigurationBytes = 1_048_576

    public init() {}

    public func parseConfiguration(_ text: String) throws -> StoreConfiguration {
        guard text.utf8.count <= Self.maximumConfigurationBytes else {
            throw OTodoError.validation(
                field: "configuration",
                message: "Configuration exceeds the 1048576-byte limit"
            )
        }
        guard !text.hasPrefix("\u{FEFF}") else {
            throw OTodoError.validation(field: "configuration", message: "A UTF-8 BOM is not allowed")
        }

        let document = try TOMLDocument.parse(text)

        // Version inspection deliberately precedes shape decoding. A client must never
        // reinterpret or validate fields whose version it does not understand.
        if case let .integer(version)? = document.topLevel["schema_version"],
           !StoreConfiguration.supportedSchemaVersions.contains(version)
        {
            throw OTodoError.unsupportedSchema(
                found: version,
                supported: StoreConfiguration.supportedSchemaVersion
            )
        }

        let topLevelKeys = Set(document.topLevel.keys)
        let expectedTopLevelKeys: Set<String> = [
            "schema_version", "tasks_directory", "projects_directory",
            "obsidian_link_prefix", "default_state",
        ]
        if let unknown = topLevelKeys.subtracting(expectedTopLevelKeys).sorted().first {
            throw OTodoError.validation(
                field: unknown,
                message: "Unknown top-level configuration key"
            )
        }
        if let section = document.unknownSections.first {
            throw OTodoError.validation(field: section, message: "Unknown configuration table")
        }

        let schemaVersion = try document.requiredInteger("schema_version")
        guard StoreConfiguration.supportedSchemaVersions.contains(schemaVersion) else {
            throw OTodoError.unsupportedSchema(
                found: schemaVersion,
                supported: StoreConfiguration.supportedSchemaVersion
            )
        }

        let tasksDirectory = try document.requiredString("tasks_directory")
        let projectsDirectory = try document.requiredString("projects_directory")
        let obsidianLinkPrefix = try document.requiredString("obsidian_link_prefix")
        let defaultState = try document.requiredString("default_state")

        guard !document.states.isEmpty else {
            throw OTodoError.validation(field: "states", message: "At least one state is required")
        }
        let stateKeys: Set<String> = ["id", "name", "terminal"]
        let states = try document.states.enumerated().map { index, table in
            if let unknown = Set(table.keys).subtracting(stateKeys).sorted().first {
                throw OTodoError.validation(
                    field: "states[\(index)].\(unknown)",
                    message: "Unknown state configuration key"
                )
            }
            return try WorkflowState(
                id: table.requiredString("id", table: "states[\(index)]"),
                name: table.requiredString("name", table: "states[\(index)]"),
                isTerminal: table.requiredBool("terminal", table: "states[\(index)]")
            )
        }

        return try StoreConfiguration(
            schemaVersion: schemaVersion,
            tasksDirectory: tasksDirectory,
            projectsDirectory: projectsDirectory,
            obsidianLinkPrefix: obsidianLinkPrefix,
            defaultState: defaultState,
            states: states
        )
    }

    /// The complete draft-2020-12 structural schema shipped with this package.
    public static func structuralSchemaJSON(schemaVersion: Int = StoreConfiguration.supportedSchemaVersion) throws -> String {
        guard StoreConfiguration.supportedSchemaVersions.contains(schemaVersion) else {
            throw OTodoError.unsupportedSchema(found: schemaVersion, supported: StoreConfiguration.supportedSchemaVersion)
        }
        let resource = schemaVersion == 1 ? "schema" : "schema-v2"
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else {
            throw OTodoError.corruptLocalState(message: "The bundled record schema is missing")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw OTodoError.corruptLocalState(
                message: "The bundled record schema could not be read: \(error.localizedDescription)"
            )
        }
    }
}

private enum TOMLValue {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case other(String)
}

private struct TOMLDocument {
    var topLevel: [String: TOMLValue] = [:]
    var states: [[String: TOMLValue]] = []
    var unknownSections: [String] = []

    private enum Section {
        case topLevel
        case state(Int)
        case unknown(String, Int)
    }

    static func parse(_ source: String) throws -> TOMLDocument {
        var result = TOMLDocument()
        var section = Section.topLevel
        var unknownValues: [[String: TOMLValue]] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        for (offset, rawSubstring) in lines.enumerated() {
            var rawLine = String(rawSubstring)
            if rawLine.hasSuffix("\r") {
                rawLine.removeLast()
            }
            let lineNumber = offset + 1
            let withoutComment = try stripComment(from: rawLine, line: lineNumber)
            let line = withoutComment.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.first == "[" {
                guard line.last == "]" else {
                    throw invalid(line: lineNumber, "Malformed TOML table header")
                }
                if line == "[[states]]" {
                    result.states.append([:])
                    section = .state(result.states.count - 1)
                } else if line.hasPrefix("[["), line.hasSuffix("]]"), line.count > 4 {
                    let name = String(line.dropFirst(2).dropLast(2))
                    guard isBareDottedKey(name) else {
                        throw invalid(line: lineNumber, "Malformed TOML array-table header")
                    }
                    result.unknownSections.append(name)
                    unknownValues.append([:])
                    section = .unknown(name, unknownValues.count - 1)
                } else if line.count > 2 {
                    let name = String(line.dropFirst().dropLast())
                    guard isBareDottedKey(name) else {
                        throw invalid(line: lineNumber, "Malformed TOML table header")
                    }
                    result.unknownSections.append(name)
                    unknownValues.append([:])
                    section = .unknown(name, unknownValues.count - 1)
                } else {
                    throw invalid(line: lineNumber, "Malformed TOML table header")
                }
                continue
            }

            let (key, value) = try parseAssignment(line, line: lineNumber)
            switch section {
            case .topLevel:
                try insert(value, key: key, into: &result.topLevel, line: lineNumber)
            case let .state(index):
                try insert(value, key: key, into: &result.states[index], line: lineNumber)
            case let .unknown(_, index):
                try insert(value, key: key, into: &unknownValues[index], line: lineNumber)
            }
        }
        return result
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = topLevel[key] else {
            throw OTodoError.validation(field: key, message: "Required configuration key is missing")
        }
        guard case let .string(string) = value else {
            throw OTodoError.validation(field: key, message: "Expected a TOML string")
        }
        return string
    }

    func requiredInteger(_ key: String) throws -> Int {
        guard let value = topLevel[key] else {
            throw OTodoError.validation(field: key, message: "Required configuration key is missing")
        }
        guard case let .integer(integer) = value else {
            throw OTodoError.validation(field: key, message: "Expected a TOML integer")
        }
        return integer
    }

    private static func parseAssignment(_ source: String, line: Int) throws -> (String, TOMLValue) {
        guard let equals = source.firstIndex(of: "=") else {
            throw invalid(line: line, "Expected a key/value assignment")
        }
        let key = source[..<equals].trimmingCharacters(in: .whitespaces)
        let rawValue = source[source.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard isBareKey(key), !rawValue.isEmpty else {
            throw invalid(line: line, "Malformed key/value assignment")
        }
        return (key, try parseValue(rawValue, line: line))
    }

    private static func parseValue(_ source: String, line: Int) throws -> TOMLValue {
        if source.first == "\"" {
            return .string(try parseBasicString(source, line: line))
        }
        if source.first == "'" {
            guard source.count >= 2, source.last == "'" else {
                throw invalid(line: line, "Unterminated TOML literal string")
            }
            let value = String(source.dropFirst().dropLast())
            guard !value.contains("'") else {
                throw invalid(line: line, "Unexpected content after TOML literal string")
            }
            return .string(value)
        }
        if source == "true" { return .bool(true) }
        if source == "false" { return .bool(false) }

        let compact = source.replacingOccurrences(of: "_", with: "")
        if isDecimalInteger(source) {
            guard let integer = Int(compact) else {
                throw invalid(line: line, "TOML integer is outside the supported range")
            }
            return .integer(integer)
        }
        return .other(source)
    }

    private static func parseBasicString(_ source: String, line: Int) throws -> String {
        var index = source.index(after: source.startIndex)
        var output = ""
        while index < source.endIndex {
            let character = source[index]
            index = source.index(after: index)
            if character == "\"" {
                guard source[index...].trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw invalid(line: line, "Unexpected content after TOML string")
                }
                return output
            }
            if character == "\\" {
                guard index < source.endIndex else {
                    throw invalid(line: line, "Unterminated TOML escape")
                }
                let escape = source[index]
                index = source.index(after: index)
                switch escape {
                case "b": output.append("\u{8}")
                case "t": output.append("\t")
                case "n": output.append("\n")
                case "f": output.append("\u{C}")
                case "r": output.append("\r")
                case "\"": output.append("\"")
                case "\\": output.append("\\")
                case "u", "U":
                    let count = escape == "u" ? 4 : 8
                    guard let scalar = parseUnicodeEscape(source, index: &index, count: count) else {
                        throw invalid(line: line, "Invalid TOML Unicode escape")
                    }
                    output.unicodeScalars.append(scalar)
                default:
                    throw invalid(line: line, "Unsupported TOML escape")
                }
            } else {
                guard character != "\n", character != "\r",
                      !character.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 })
                else {
                    throw invalid(line: line, "Control character in TOML string")
                }
                output.append(character)
            }
        }
        throw invalid(line: line, "Unterminated TOML string")
    }

    private static func parseUnicodeEscape(
        _ source: String,
        index: inout String.Index,
        count: Int
    ) -> UnicodeScalar? {
        var digits = ""
        for _ in 0 ..< count {
            guard index < source.endIndex else { return nil }
            let character = source[index]
            guard character.isHexDigit else { return nil }
            digits.append(character)
            index = source.index(after: index)
        }
        guard let value = UInt32(digits, radix: 16),
              !(0xD800 ... 0xDFFF).contains(value),
              let scalar = UnicodeScalar(value)
        else { return nil }
        return scalar
    }

    private static func stripComment(from source: String, line: Int) throws -> String {
        var inBasic = false
        var inLiteral = false
        var escaped = false
        for index in source.indices {
            let character = source[index]
            if inBasic {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inBasic = false
                }
            } else if inLiteral {
                if character == "'" { inLiteral = false }
            } else if character == "\"" {
                inBasic = true
            } else if character == "'" {
                inLiteral = true
            } else if character == "#" {
                return String(source[..<index])
            }
        }
        if inBasic || inLiteral || escaped {
            throw invalid(line: line, "Unterminated TOML string")
        }
        return source
    }

    private static func insert(
        _ value: TOMLValue,
        key: String,
        into values: inout [String: TOMLValue],
        line: Int
    ) throws {
        guard values.updateValue(value, forKey: key) == nil else {
            throw invalid(line: line, "Duplicate TOML key \"\(key)\"")
        }
    }

    private static func isBareKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) ||
                (97 ... 122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func isBareDottedKey(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { isBareKey(String($0)) }
    }

    private static func isDecimalInteger(_ value: String) -> Bool {
        var bytes = Array(value.utf8)
        if bytes.first == 43 || bytes.first == 45 { bytes.removeFirst() }
        guard !bytes.isEmpty, bytes.first != 95, bytes.last != 95 else { return false }
        guard bytes.count == 1 || bytes.first != 48 else { return false }
        var previousUnderscore = false
        for byte in bytes {
            if byte == 95 {
                if previousUnderscore { return false }
                previousUnderscore = true
            } else if (48 ... 57).contains(byte) {
                previousUnderscore = false
            } else {
                return false
            }
        }
        return !previousUnderscore
    }

    private static func invalid(line: Int, _ message: String) -> OTodoError {
        .validation(field: "configuration", message: "Line \(line): \(message)")
    }
}

private extension Dictionary where Key == String, Value == TOMLValue {
    func requiredString(_ key: String, table: String) throws -> String {
        guard let value = self[key] else {
            throw OTodoError.validation(field: "\(table).\(key)", message: "Required key is missing")
        }
        guard case let .string(string) = value else {
            throw OTodoError.validation(field: "\(table).\(key)", message: "Expected a TOML string")
        }
        return string
    }

    func requiredBool(_ key: String, table: String) throws -> Bool {
        guard let value = self[key] else {
            throw OTodoError.validation(field: "\(table).\(key)", message: "Required key is missing")
        }
        guard case let .bool(bool) = value else {
            throw OTodoError.validation(field: "\(table).\(key)", message: "Expected a TOML boolean")
        }
        return bool
    }
}
