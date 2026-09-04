import Foundation
import Yams

public struct ObsidianTaskCodec: TaskRecordCoding, Sendable {
    public static let maximumRecordBytes = 8 * 1024 * 1024
    public static let maximumYAMLDepth = 64
    public static let maximumYAMLNodes = 100_000

    private static let coreKeys: Set<String> = [
        "name", "state", "projects", "tags", "due_date", "due_time", "recurrence",
        "recurrence_from", "last_completed_date",
    ]

    public init() {}

    public func parseTask(
        id: TaskID,
        relativePath: String,
        text: String,
        configuration: StoreConfiguration
    ) throws -> TodoTask {
        let document = try FrontMatterEnvelope.parse(text)
        let properties = try SafeYAML.parseMapping(document.yaml)

        if properties.contains(where: { $0.name == "id" }) {
            throw OTodoError.validation(
                field: "id",
                message: "Record identity belongs only in its filename; remove the id property"
            )
        }

        var values: [String: YAMLValue] = [:]
        var extras: [YAMLProperty] = []
        for property in properties {
            if Self.coreKeys.contains(property.name) {
                values[property.name] = property.value
            } else {
                extras.append(property)
            }
        }

        let name = try Self.requiredString(values, key: "name")
        let state = try Self.requiredString(values, key: "state")
        let projectLinks = try Self.requiredStringList(values, key: "projects")
        let tags = try Self.requiredStringList(values, key: "tags")
        let dueDate = try Self.optionalDate(values, key: "due_date")
        let dueTime = try Self.optionalTime(values, key: "due_time")
        let recurrenceSource = try Self.optionalString(values, key: "recurrence")
        let recurrenceFromSource = try Self.optionalString(values, key: "recurrence_from")
        let lastCompletedDate = try Self.optionalDate(values, key: "last_completed_date")

        guard configuration.states.contains(where: { $0.id == state }) else {
            throw OTodoError.validation(field: "state", message: "Task state is not configured")
        }

        let projectSlugs = try projectLinks.map {
            try Self.parseProjectLink($0, configuration: configuration)
        }
        let recurrenceFrom: RecurrenceFrom?
        if let recurrenceFromSource {
            guard let parsed = RecurrenceFrom(rawValue: recurrenceFromSource) else {
                throw OTodoError.validation(
                    field: "recurrence_from",
                    message: "Expected 'schedule' or 'completion'"
                )
            }
            recurrenceFrom = parsed
        } else {
            recurrenceFrom = nil
        }
        let rule = try RecurrenceRule.validatePresence(
            recurrence: recurrenceSource,
            recurrenceFrom: recurrenceFrom,
            dueDate: dueDate,
            lastCompletedDate: lastCompletedDate
        )

        return try TodoTask(
            id: id,
            relativePath: relativePath,
            name: name,
            state: state,
            projectSlugs: projectSlugs,
            tags: tags,
            dueDate: dueDate,
            dueTime: dueTime,
            recurrence: rule?.description,
            recurrenceFrom: recurrenceFrom,
            lastCompletedDate: lastCompletedDate,
            body: document.body,
            extraProperties: extras
        )
    }

    public func serializeTask(
        _ task: TodoTask,
        configuration: StoreConfiguration
    ) throws -> String {
        guard configuration.states.contains(where: { $0.id == task.state }) else {
            throw OTodoError.validation(field: "state", message: "Task state is not configured")
        }
        try FrontMatterEnvelope.rejectConflictMarkers(task.body)

        let rule = try RecurrenceRule.validatePresence(
            recurrence: task.recurrence,
            recurrenceFrom: task.recurrenceFrom,
            dueDate: task.dueDate,
            lastCompletedDate: task.lastCompletedDate
        )
        _ = try TodoTask(
            id: task.id,
            relativePath: task.relativePath,
            name: task.name,
            state: task.state,
            projectSlugs: task.projectSlugs,
            tags: task.tags,
            dueDate: task.dueDate,
            dueTime: task.dueTime,
            recurrence: rule?.description,
            recurrenceFrom: task.recurrenceFrom,
            lastCompletedDate: task.lastCompletedDate,
            body: task.body,
            extraProperties: task.extraProperties
        )
        try SafeYAML.validateProperties(task.extraProperties, reserved: Self.coreKeys.union(["id"]))

        let projects = try task.projectSlugs.sorted(by: Self.utf8Less).map {
            try configuration.projectLink(slug: $0)
        }
        let tags = task.tags.sorted(by: Self.utf8Less)

        var output = "---\n"
        output += "name: \(try YAMLWriter.quoted(task.name))\n"
        output += "state: \(try Self.renderState(task.state))\n"
        try YAMLWriter.appendStringList(projects, key: "projects", to: &output)
        try YAMLWriter.appendStringList(tags, key: "tags", to: &output)
        if let dueDate = task.dueDate {
            output += "due_date: \(dueDate.rawValue)\n"
        }
        if let dueTime = task.dueTime {
            output += "due_time: \(try YAMLWriter.quoted(dueTime.rawValue))\n"
        }
        if let rule {
            output += "recurrence: \(try YAMLWriter.quoted(rule.description))\n"
        }
        if let recurrenceFrom = task.recurrenceFrom {
            output += "recurrence_from: \(recurrenceFrom.rawValue)\n"
        }
        if let lastCompletedDate = task.lastCompletedDate {
            output += "last_completed_date: \(lastCompletedDate.rawValue)\n"
        }
        try YAMLWriter.appendProperties(task.extraProperties, indentation: 0, to: &output)
        output += "---\n"
        output += task.body

        guard output.utf8.count <= Self.maximumRecordBytes else {
            throw OTodoError.validation(
                field: "record",
                message: "Markdown record exceeds the \(Self.maximumRecordBytes)-byte limit"
            )
        }
        return output
    }

    private static func requiredString(
        _ values: [String: YAMLValue],
        key: String
    ) throws -> String {
        guard let value = values[key] else {
            throw OTodoError.validation(field: key, message: "Required property is missing")
        }
        guard case let .string(string) = value else {
            throw OTodoError.validation(field: key, message: "Property must be a string")
        }
        return string
    }

    private static func requiredStringList(
        _ values: [String: YAMLValue],
        key: String
    ) throws -> [String] {
        guard let value = values[key] else {
            throw OTodoError.validation(field: key, message: "Required property is missing")
        }
        guard case let .sequence(items) = value else {
            throw OTodoError.validation(field: key, message: "Property must be a list")
        }
        return try items.map { item in
            guard case let .string(string) = item else {
                throw OTodoError.validation(field: key, message: "Every list item must be a string")
            }
            return string
        }
    }

    private static func optionalString(
        _ values: [String: YAMLValue],
        key: String
    ) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case let .string(string) = value else {
            throw OTodoError.validation(field: key, message: "Property must be a string")
        }
        return string
    }

    private static func optionalDate(
        _ values: [String: YAMLValue],
        key: String
    ) throws -> CivilDate? {
        guard let value = values[key] else { return nil }
        guard case let .string(string) = value else {
            throw OTodoError.validation(field: key, message: "Property must be a date scalar")
        }
        do {
            return try CivilDate(rawValue: string)
        } catch {
            throw OTodoError.validation(field: key, message: "Expected a valid YYYY-MM-DD date")
        }
    }

    private static func optionalTime(
        _ values: [String: YAMLValue],
        key: String
    ) throws -> CivilTime? {
        guard let value = values[key] else { return nil }
        guard case let .string(string) = value else {
            throw OTodoError.validation(field: key, message: "Property must be a time scalar")
        }
        do {
            return try CivilTime(rawValue: string)
        } catch {
            throw OTodoError.validation(field: key, message: "Expected a valid HH:mm time")
        }
    }

    private static func parseProjectLink(
        _ link: String,
        configuration: StoreConfiguration
    ) throws -> String {
        let directoryPrefix: String
        if configuration.obsidianLinkPrefix.isEmpty {
            directoryPrefix = configuration.projectsDirectory + "/"
        } else {
            directoryPrefix = configuration.obsidianLinkPrefix + "/" +
                configuration.projectsDirectory + "/"
        }
        let prefix = "[[" + directoryPrefix
        guard link.hasPrefix(prefix), link.hasSuffix("]]"), link.count > prefix.count + 2 else {
            throw invalidProjectLink(link, configuration: configuration)
        }
        let slugStart = link.index(link.startIndex, offsetBy: prefix.count)
        let slugEnd = link.index(link.endIndex, offsetBy: -2)
        let slug = String(link[slugStart ..< slugEnd])
        guard !slug.contains("/"), !slug.contains("|"), !slug.contains("#"), !slug.contains("^"),
              !slug.hasSuffix(".md")
        else {
            throw invalidProjectLink(link, configuration: configuration)
        }
        do {
            guard try configuration.projectLink(slug: slug) == link else {
                throw invalidProjectLink(link, configuration: configuration)
            }
        } catch {
            throw invalidProjectLink(link, configuration: configuration)
        }
        return slug
    }

    private static func invalidProjectLink(
        _ link: String,
        configuration: StoreConfiguration
    ) -> OTodoError {
        let directory = configuration.obsidianLinkPrefix.isEmpty
            ? configuration.projectsDirectory
            : configuration.obsidianLinkPrefix + "/" + configuration.projectsDirectory
        return .validation(
            field: "projects",
            message: "Project reference \"\(link)\" must be an unaliased wikilink under \(directory)/"
        )
    }

    private static func renderState(_ state: String) throws -> String {
        let keywords: Set<String> = ["null", "true", "false", "yes", "no", "on", "off", "y", "n"]
        if state.utf8.first.map({ (48 ... 57).contains($0) }) == true || keywords.contains(state) {
            return try YAMLWriter.quoted(state)
        }
        return state
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

private struct FrontMatterEnvelope {
    let yaml: String
    let body: String

    static func parse(_ source: String) throws -> FrontMatterEnvelope {
        let bytes = source.utf8
        guard bytes.count <= ObsidianTaskCodec.maximumRecordBytes else {
            throw OTodoError.validation(
                field: "record",
                message: "Markdown record exceeds the \(ObsidianTaskCodec.maximumRecordBytes)-byte limit"
            )
        }
        guard !source.hasPrefix("\u{FEFF}") else {
            throw OTodoError.validation(
                field: "frontMatter",
                message: "Front matter must begin at byte zero; a UTF-8 BOM is not allowed"
            )
        }
        try rejectConflictMarkers(source)

        let openingDelimiterLength: Int
        if bytes.starts(with: "---\n".utf8) {
            openingDelimiterLength = 4
        } else if bytes.starts(with: "---\r\n".utf8) {
            openingDelimiterLength = 5
        } else {
            throw OTodoError.validation(
                field: "frontMatter",
                message: "Front matter must begin with '---' at byte zero"
            )
        }

        let yamlStart = bytes.index(bytes.startIndex, offsetBy: openingDelimiterLength)
        var lineStart = yamlStart
        var cursor = yamlStart
        while cursor < bytes.endIndex {
            guard bytes[cursor] == 0x0A else {
                cursor = bytes.index(after: cursor)
                continue
            }

            var lineEnd = cursor
            if lineEnd > lineStart {
                let previous = bytes.index(before: lineEnd)
                if bytes[previous] == 0x0D {
                    lineEnd = previous
                }
            }
            if bytes[lineStart ..< lineEnd].elementsEqual("---".utf8) {
                let bodyStart = bytes.index(after: cursor)
                return FrontMatterEnvelope(
                    yaml: String(decoding: bytes[yamlStart ..< lineStart], as: UTF8.self),
                    body: String(decoding: bytes[bodyStart...], as: UTF8.self)
                )
            }
            cursor = bytes.index(after: cursor)
            lineStart = cursor
        }
        throw OTodoError.validation(
            field: "frontMatter",
            message: "Front matter requires a closing '---' line terminated by a newline"
        )
    }

    static func rejectConflictMarkers(_ source: String) throws {
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]
            if ["<<<<<<<", "|||||||", "=======", ">>>>>>>"].contains(where: { line.hasPrefix($0) }) {
                throw OTodoError.conflict(message: "Markdown record contains an unresolved conflict marker")
            }
        }
    }
}

private enum YAMLPreflight {
    static func validate(_ source: String) throws {
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        var blockScalarIndent: Int?
        var plainScalarIndent: Int?
        var flowDepth = 0
        var blockIndents: [Int] = []
        blockIndents.reserveCapacity(ObsidianTaskCodec.maximumYAMLDepth)
        var nodeCount = 0

        var lineStart = source.startIndex
        while lineStart < source.endIndex {
            let newline = source[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? source.endIndex
            let line = source[lineStart ..< lineEnd]
            let quotedContinuation = singleQuoted || doubleQuoted
            let indentation = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let parentIndent = blockScalarIndent {
                if trimmed.isEmpty || indentation > parentIndent {
                    guard let newline else { break }
                    lineStart = source.index(after: newline)
                    continue
                }
                blockScalarIndent = nil
            }

            let content = line.dropFirst(indentation)
            let structuralIndicator =
                content == "-" || content == "?" ||
                content.hasPrefix("- ") || content.hasPrefix("? ")
            let plainContinuation: Bool
            if let parentIndent = plainScalarIndent,
               !structuralIndicator,
               trimmed.isEmpty || indentation > parentIndent
            {
                plainContinuation = true
            } else {
                plainScalarIndent = nil
                plainContinuation = false
            }
            let startsInFlow = flowDepth > 0
            if !quotedContinuation,
               !plainContinuation,
               !startsInFlow,
               !trimmed.isEmpty,
               !content.hasPrefix("#")
            {
                while let parent = blockIndents.last, indentation <= parent {
                    blockIndents.removeLast()
                }
                blockIndents.append(indentation)
                try requireDepth(block: blockIndents.count, compact: 0, flow: flowDepth)
            }

            var tokenStart = true
            var valuePosition = false
            var compactDepth = 0
            var plainScalar = plainContinuation
            var structuralLine = false
            var index = line.startIndex
            while index < line.endIndex {
                let character = line[index]
                let nextIndex = line.index(after: index)

                if doubleQuoted {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        doubleQuoted = false
                    }
                    index = nextIndex
                    continue
                }
                if singleQuoted {
                    if character == "'" {
                        singleQuoted = false
                    }
                    index = nextIndex
                    continue
                }

                if tokenStart, !plainScalar {
                    if character == "&" || character == "*" || character == "!" {
                        throw unsafe("YAML tags, anchors, and aliases are not supported")
                    }
                    if character == "<", isPlainMergeKey(in: line, at: index) {
                        throw unsafe("YAML merge keys are not supported")
                    }
                    if (character == "'" || character == "\""),
                       isDirectQuotedMergeKey(in: line, at: index, quote: character)
                    {
                        throw unsafe("YAML merge keys are not supported")
                    }
                }

                switch character {
                case "#" where tokenStart:
                    index = line.endIndex
                    continue
                case "\"" where !plainScalar:
                    try countNode(&nodeCount)
                    doubleQuoted = true
                    valuePosition = false
                case "'" where !plainScalar:
                    try countNode(&nodeCount)
                    singleQuoted = true
                    valuePosition = false
                case ":":
                    let next: Character? = nextIndex < line.endIndex ? line[nextIndex] : nil
                    let separatesValue = next == nil ||
                        next?.isWhitespace == true ||
                        (flowDepth > 0 && next.map { ",[]{}".contains($0) } == true)
                    if separatesValue {
                        try countNode(&nodeCount)
                        structuralLine = true
                        plainScalar = false
                        valuePosition = true
                    }
                case "?" where tokenStart && !plainScalar:
                    valuePosition = nextIndex < line.endIndex && line[nextIndex].isWhitespace
                    if valuePosition {
                        try countNode(&nodeCount)
                        compactDepth += 1
                        try requireDepth(
                            block: blockIndents.count,
                            compact: compactDepth,
                            flow: flowDepth
                        )
                    } else {
                        plainScalar = true
                        try countNode(&nodeCount)
                    }
                case "-" where tokenStart && !plainScalar:
                    valuePosition = nextIndex < line.endIndex && line[nextIndex].isWhitespace
                    if valuePosition {
                        try countNode(&nodeCount)
                        compactDepth += 1
                        try requireDepth(
                            block: blockIndents.count,
                            compact: compactDepth,
                            flow: flowDepth
                        )
                    } else {
                        plainScalar = true
                        try countNode(&nodeCount)
                    }
                case "|" where valuePosition && isBlockScalarSuffix(line[nextIndex...]),
                     ">" where valuePosition && isBlockScalarSuffix(line[nextIndex...]):
                    try countNode(&nodeCount)
                    blockScalarIndent = indentation
                    index = line.endIndex
                    continue
                case "[" where !plainScalar, "{" where !plainScalar:
                    try countNode(&nodeCount)
                    flowDepth += 1
                    try requireDepth(
                        block: blockIndents.count,
                        compact: compactDepth,
                        flow: flowDepth
                    )
                    plainScalar = false
                    valuePosition = true
                case "," where flowDepth > 0:
                    plainScalar = false
                    valuePosition = true
                case "]" where flowDepth > 0, "}" where flowDepth > 0:
                    flowDepth -= 1
                    plainScalar = false
                    valuePosition = false
                case let character where !character.isWhitespace:
                    if !plainScalar {
                        try countNode(&nodeCount)
                    }
                    plainScalar = true
                    valuePosition = false
                default:
                    break
                }
                tokenStart = character.isWhitespace || ":,[]{}-?".contains(character)
                index = nextIndex
            }

            if plainContinuation, structuralLine, !startsInFlow {
                while let parent = blockIndents.last, indentation <= parent {
                    blockIndents.removeLast()
                }
                blockIndents.append(indentation)
                try requireDepth(block: blockIndents.count, compact: 0, flow: flowDepth)
            }
            if plainScalar, !plainContinuation || structuralLine {
                plainScalarIndent = indentation
            } else if structuralLine {
                plainScalarIndent = nil
            }
            escaped = false

            guard let newline else { break }
            lineStart = source.index(after: newline)
        }
    }

    private static func countNode(_ count: inout Int) throws {
        count += 1
        guard count <= ObsidianTaskCodec.maximumYAMLNodes else {
            throw OTodoError.validation(
                field: "frontMatter",
                message: "YAML front matter contains too many values"
            )
        }
    }

    private static func requireDepth(block: Int, compact: Int, flow: Int) throws {
        guard block + compact + flow <= ObsidianTaskCodec.maximumYAMLDepth else {
            throw OTodoError.validation(
                field: "frontMatter",
                message: "YAML front matter exceeds the supported nesting depth"
            )
        }
    }

    private static func isBlockScalarSuffix(_ suffix: Substring) -> Bool {
        let trimmed = suffix.trimmingCharacters(in: .whitespaces)
        let modifiers: Substring
        if let comment = trimmed.firstIndex(of: "#") {
            if comment != trimmed.startIndex {
                let previous = trimmed.index(before: comment)
                guard trimmed[previous].isWhitespace else { return false }
            }
            modifiers = trimmed[..<comment].drop(while: { $0.isWhitespace })
        } else {
            modifiers = trimmed[...]
        }

        var sawIndentation = false
        var sawChomping = false
        for modifier in modifiers {
            if let digit = modifier.wholeNumberValue,
               (1 ... 9).contains(digit),
               !sawIndentation
            {
                sawIndentation = true
            } else if (modifier == "+" || modifier == "-"), !sawChomping {
                sawChomping = true
            } else {
                return false
            }
        }
        return true
    }

    private static func isPlainMergeKey(in line: Substring, at index: String.Index) -> Bool {
        let suffix = line[index...]
        guard suffix.hasPrefix("<<") else { return false }
        var remainder = suffix.dropFirst(2)
        remainder = remainder.drop(while: { $0.isWhitespace })
        return remainder.first == ":"
    }

    private static func isDirectQuotedMergeKey(
        in line: Substring,
        at index: String.Index,
        quote: Character
    ) -> Bool {
        let suffix = line[index...]
        let spelling = quote == "'" ? "'<<'" : "\"<<\""
        guard suffix.hasPrefix(spelling) else { return false }
        var remainder = suffix.dropFirst(spelling.count)
        remainder = remainder.drop(while: { $0.isWhitespace })
        return remainder.first == ":"
    }

    private static func unsafe(_ message: String) -> OTodoError {
        .validation(field: "frontMatter", message: message)
    }
}

private enum SafeYAML {
    private static let yaml12Resolver: Resolver = {
        do {
            return try Resolver.basic
                .appending(.null, #"^(?:null|Null|NULL|~|)$"#)
                .appending(.bool, #"^(?:true|True|TRUE|false|False|FALSE)$"#)
                .appending(.int, #"^[-+]?(?:0|[1-9][0-9]*|0b[0-1]+|0o[0-7]+|0x[0-9a-fA-F]+)$"#)
                .appending(
                    .float,
                    #"^[-+]?(?:(?:[0-9]+\.[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?|[0-9]+[eE][-+]?[0-9]+)$"#
                )
        } catch {
            preconditionFailure("Invalid built-in YAML 1.2 resolver: \(error)")
        }
    }()

    static func parseMapping(_ source: String) throws -> [YAMLProperty] {
        if source.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy({ line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }) {
            return []
        }

        do {
            try YAMLPreflight.validate(source)
            let parser = try Parser(
                yaml: source,
                resolver: yaml12Resolver,
                encoding: .utf8
            )
            return try withExtendedLifetime(parser) {
                guard let root = try parser.singleRoot() else { return [] }
                var count = 0
                let value = try convert(root, depth: 0, count: &count)
                guard case let .mapping(properties) = value else {
                    throw OTodoError.validation(
                        field: "frontMatter",
                        message: "YAML front matter must be a property mapping"
                    )
                }
                return properties
            }
        } catch let error as OTodoError {
            throw error
        } catch {
            throw OTodoError.validation(
                field: "frontMatter",
                message: "Invalid YAML syntax: \(error.localizedDescription)"
            )
        }
    }

    static func validateProperties(_ properties: [YAMLProperty], reserved: Set<String>) throws {
        let names = properties.map(\.name)
        guard Set(names).count == names.count else {
            throw OTodoError.validation(field: "extraProperties", message: "Property names must be unique")
        }
        if let name = names.first(where: reserved.contains) {
            throw OTodoError.validation(
                field: name,
                message: "Extra properties cannot contain a reserved task property"
            )
        }
        var count = 0
        _ = try validate(.mapping(properties), depth: 0, count: &count)
    }

    private static func convert(_ node: Node, depth: Int, count: inout Int) throws -> YAMLValue {
        try countNode(depth: depth, count: &count)
        if node.anchor != nil {
            throw unsafe("YAML anchors and aliases are not supported")
        }

        switch node {
        case .alias:
            throw unsafe("YAML aliases are not supported")
        case let .sequence(sequence):
            let tag = sequence.tag.rawValue
            guard tag.isEmpty || tag == "tag:yaml.org,2002:seq" else {
                throw unsafe("Unsupported YAML sequence tag")
            }
            return .sequence(try sequence.map { try convert($0, depth: depth + 1, count: &count) })
        case let .mapping(mapping):
            let tag = mapping.tag.rawValue
            guard tag.isEmpty || tag == "tag:yaml.org,2002:map" else {
                throw unsafe("Unsupported YAML mapping tag")
            }
            var names: Set<String> = []
            var properties: [YAMLProperty] = []
            properties.reserveCapacity(mapping.count)
            for (keyNode, valueNode) in mapping {
                let keyValue = try convert(keyNode, depth: depth + 1, count: &count)
                guard case let .string(name) = keyValue else {
                    throw OTodoError.validation(
                        field: "frontMatter",
                        message: "YAML mapping keys must be strings"
                    )
                }
                guard name != "<<" else {
                    throw unsafe("YAML merge keys are not supported")
                }
                guard names.insert(name).inserted else {
                    throw OTodoError.validation(
                        field: name,
                        message: "Duplicate YAML mapping key"
                    )
                }
                let value = try convert(valueNode, depth: depth + 1, count: &count)
                properties.append(YAMLProperty(name: name, value: value))
            }
            return .mapping(properties)
        case let .scalar(scalar):
            if scalar.style == .plain, isNonFiniteFloat(scalar.string) {
                throw OTodoError.validation(
                    field: "frontMatter",
                    message: "YAML numbers must have a finite representation"
                )
            }
            switch node.tag.rawValue {
            case "tag:yaml.org,2002:null":
                return .null
            case "tag:yaml.org,2002:bool":
                guard let value = node.bool else {
                    throw unsupportedScalar(scalar.string)
                }
                return .bool(value)
            case "tag:yaml.org,2002:int":
                guard let value = parseInteger(scalar.string) else {
                    throw unsupportedScalar(scalar.string)
                }
                return .integer(value)
            case "tag:yaml.org,2002:float":
                guard let value = node.float, value.isFinite else {
                    throw OTodoError.validation(
                        field: "frontMatter",
                        message: "YAML numbers must have a finite representation"
                    )
                }
                return .double(value)
            case "tag:yaml.org,2002:str":
                return .string(scalar.string)
            default:
                throw unsupportedScalar(scalar.string)
            }
        }
    }

    private static func validate(
        _ value: YAMLValue,
        depth: Int,
        count: inout Int
    ) throws -> YAMLValue {
        try countNode(depth: depth, count: &count)
        switch value {
        case let .double(number):
            guard number.isFinite else {
                throw OTodoError.validation(field: "extraProperties", message: "YAML numbers must be finite")
            }
        case let .sequence(values):
            for value in values { _ = try validate(value, depth: depth + 1, count: &count) }
        case let .mapping(properties):
            let names = properties.map(\.name)
            guard names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count else {
                throw OTodoError.validation(
                    field: "extraProperties",
                    message: "Nested YAML mapping keys must be nonempty and unique"
                )
            }
            guard !names.contains("<<") else {
                throw unsafe("YAML merge keys are not supported")
            }
            for property in properties {
                _ = try validate(property.value, depth: depth + 1, count: &count)
            }
        case .null, .bool, .integer, .string:
            break
        }
        return value
    }

    private static func countNode(depth: Int, count: inout Int) throws {
        guard depth <= ObsidianTaskCodec.maximumYAMLDepth else {
            throw OTodoError.validation(
                field: "frontMatter",
                message: "YAML front matter exceeds the supported nesting depth"
            )
        }
        count += 1
        guard count <= ObsidianTaskCodec.maximumYAMLNodes else {
            throw OTodoError.validation(
                field: "frontMatter",
                message: "YAML front matter contains too many values"
            )
        }
    }

    private static func parseInteger(_ source: String) -> Int64? {
        var digits = source[...]
        let isNegative = digits.first == "-"
        if digits.first == "-" || digits.first == "+" {
            digits.removeFirst()
        }

        let radix: Int
        if digits.hasPrefix("0b") {
            radix = 2
            digits = digits.dropFirst(2)
        } else if digits.hasPrefix("0o") {
            radix = 8
            digits = digits.dropFirst(2)
        } else if digits.hasPrefix("0x") {
            radix = 16
            digits = digits.dropFirst(2)
        } else {
            radix = 10
        }
        guard let magnitude = UInt64(digits, radix: radix) else { return nil }
        if isNegative {
            let limit = UInt64(Int64.max) + 1
            guard magnitude <= limit else { return nil }
            return magnitude == limit ? Int64.min : -Int64(magnitude)
        }
        guard magnitude <= UInt64(Int64.max) else { return nil }
        return Int64(magnitude)
    }

    private static func isNonFiniteFloat(_ source: String) -> Bool {
        switch source.lowercased() {
        case ".inf", "+.inf", "-.inf", ".nan":
            return true
        default:
            return false
        }
    }

    private static func unsafe(_ message: String) -> OTodoError {
        .validation(field: "frontMatter", message: message)
    }

    private static func unsupportedScalar(_ source: String) -> OTodoError {
        .validation(
            field: "frontMatter",
            message: "YAML scalar \"\(source)\" cannot be represented safely"
        )
    }
}

private enum YAMLWriter {
    static func quoted(_ value: String) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(value)
            guard let rendered = String(data: data, encoding: .utf8) else {
                throw OTodoError.validation(field: "frontMatter", message: "Could not encode YAML string")
            }
            return rendered
        } catch let error as OTodoError {
            throw error
        } catch {
            throw OTodoError.validation(
                field: "frontMatter",
                message: "Could not encode YAML string: \(error.localizedDescription)"
            )
        }
    }

    static func appendStringList(
        _ values: [String],
        key: String,
        to output: inout String
    ) throws {
        if values.isEmpty {
            output += "\(key): []\n"
            return
        }
        output += "\(key):\n"
        for value in values {
            output += "  - \(try quoted(value))\n"
        }
    }

    static func appendProperties(
        _ properties: [YAMLProperty],
        indentation: Int,
        to output: inout String
    ) throws {
        for property in properties {
            let prefix = String(repeating: " ", count: indentation)
            output += prefix + (try renderKey(property.name)) + ":"
            try appendValue(property.value, indentation: indentation, to: &output)
        }
    }

    private static func appendValue(
        _ value: YAMLValue,
        indentation: Int,
        to output: inout String
    ) throws {
        switch value {
        case .null, .bool, .integer, .double, .string:
            output += " " + (try renderScalar(value)) + "\n"
        case let .sequence(values):
            if values.isEmpty {
                output += " []\n"
            } else {
                output += "\n"
                for value in values {
                    output += String(repeating: " ", count: indentation + 2) + "-"
                    switch value {
                    case .null, .bool, .integer, .double, .string:
                        output += " " + (try renderScalar(value)) + "\n"
                    case .sequence, .mapping:
                        output += "\n"
                        try appendNested(value, indentation: indentation + 4, to: &output)
                    }
                }
            }
        case let .mapping(properties):
            if properties.isEmpty {
                output += " {}\n"
            } else {
                output += "\n"
                try appendProperties(properties, indentation: indentation + 2, to: &output)
            }
        }
    }

    private static func appendNested(
        _ value: YAMLValue,
        indentation: Int,
        to output: inout String
    ) throws {
        switch value {
        case let .mapping(properties):
            if properties.isEmpty {
                output += String(repeating: " ", count: indentation) + "{}\n"
            } else {
                try appendProperties(properties, indentation: indentation, to: &output)
            }
        case let .sequence(values):
            if values.isEmpty {
                output += String(repeating: " ", count: indentation) + "[]\n"
            } else {
                for value in values {
                    output += String(repeating: " ", count: indentation) + "-"
                    switch value {
                    case .null, .bool, .integer, .double, .string:
                        output += " " + (try renderScalar(value)) + "\n"
                    case .sequence, .mapping:
                        output += "\n"
                        try appendNested(value, indentation: indentation + 2, to: &output)
                    }
                }
            }
        case .null, .bool, .integer, .double, .string:
            output += String(repeating: " ", count: indentation) + (try renderScalar(value)) + "\n"
        }
    }

    private static func renderScalar(_ value: YAMLValue) throws -> String {
        switch value {
        case .null:
            return "null"
        case let .bool(bool):
            return bool ? "true" : "false"
        case let .integer(integer):
            return String(integer)
        case let .double(double):
            guard double.isFinite else {
                throw OTodoError.validation(field: "extraProperties", message: "YAML numbers must be finite")
            }
            return String(double)
        case let .string(string):
            return try quoted(string)
        case .sequence, .mapping:
            throw OTodoError.validation(field: "extraProperties", message: "Expected a scalar YAML value")
        }
    }

    private static func renderKey(_ key: String) throws -> String {
        let bytes = Array(key.utf8)
        if let first = bytes.first,
           (65 ... 90).contains(first) || (97 ... 122).contains(first) || first == 95,
           bytes.dropFirst().allSatisfy({
               (48 ... 57).contains($0) || (65 ... 90).contains($0) ||
                   (97 ... 122).contains($0) || $0 == 45 || $0 == 95
           })
        {
            return key
        }
        return try quoted(key)
    }
}
