import Foundation

public struct TaskFilterQuery: Sendable {
    private let expression: Expression

    public static let all = TaskFilterQuery(expression: .all)
    public static let active = TaskFilterQuery(expression: .active)
    public static let today = TaskFilterQuery(expression: .today)
    public static let overdue = TaskFilterQuery(expression: .overdue)
    public static let tomorrow = TaskFilterQuery(expression: .tomorrow)
    public static let nextSevenDays = TaskFilterQuery(expression: .nextSevenDays)
    public static let undated = TaskFilterQuery(expression: .undated)
    public static let inbox = TaskFilterQuery(expression: .inbox)

    public init(_ source: String) throws {
        guard source.utf8.prefix(16_385).count <= 16_384 else {
            throw OTodoError.validation(field: "filterQuery", message: "Query must not exceed 16384 UTF-8 bytes")
        }
        var parser = try Parser(source)
        expression = try parser.parse()
    }

    private init(expression: Expression) {
        self.expression = expression
    }

    public func matches(_ task: TodoTask, terminalStateIDs: Set<String>, dates: TaskDateContext) throws -> Bool {
        try Task.checkCancellation()
        let result = try expression.matches(task, terminalStateIDs: terminalStateIDs, dates: dates)
        try Task.checkCancellation()
        return result
    }

    private indirect enum Expression: Sendable {
        case all
        case active
        case today
        case overdue
        case tomorrow
        case nextSevenDays
        case undated
        case due(ClosedRange<CivilDate>)
        case inbox
        case tag(String)
        case project(String)
        case name(NSRegularExpression)
        case description(NSRegularExpression)
        case not(Expression)
        case and([Expression])
        case or([Expression])

        func matches(_ task: TodoTask, terminalStateIDs: Set<String>, dates: TaskDateContext) throws -> Bool {
            try Task.checkCancellation()
            switch self {
            case .all:
                return true
            case .active:
                return !terminalStateIDs.contains(task.state)
            case .today:
                return !terminalStateIDs.contains(task.state) && task.dueDate.map { $0.rawValue <= dates.today } == true
            case .overdue:
                return !terminalStateIDs.contains(task.state) && task.dueDate.map { $0.rawValue < dates.today } == true
            case .tomorrow:
                return !terminalStateIDs.contains(task.state) && task.dueDate?.rawValue == dates.tomorrow
            case .nextSevenDays:
                return !terminalStateIDs.contains(task.state) && task.dueDate.map {
                    $0.rawValue >= dates.tomorrow && $0.rawValue <= dates.endOfNextSevenDays
                } == true
            case .undated:
                return !terminalStateIDs.contains(task.state) && task.dueDate == nil
            case let .due(range):
                return !terminalStateIDs.contains(task.state) && task.dueDate.map { range.contains($0) } == true
            case .inbox:
                return task.projectSlugs.isEmpty && !terminalStateIDs.contains(task.state)
            case let .tag(value):
                return task.tags.contains(value)
            case let .project(value):
                return task.projectSlugs.contains(value)
            case let .name(regex):
                return try Self.matches(regex, in: task.name)
            case let .description(regex):
                return try Self.matches(regex, in: task.body)
            case let .not(expression):
                return try !expression.matches(task, terminalStateIDs: terminalStateIDs, dates: dates)
            case let .and(expressions):
                for expression in expressions {
                    if try !expression.matches(task, terminalStateIDs: terminalStateIDs, dates: dates) {
                        return false
                    }
                }
                return true
            case let .or(expressions):
                for expression in expressions {
                    if try expression.matches(task, terminalStateIDs: terminalStateIDs, dates: dates) {
                        return true
                    }
                }
                return false
            }
        }

        private static func matches(_ regex: NSRegularExpression, in text: String) throws -> Bool {
            var found = false
            var failed = false
            regex.enumerateMatches(
                in: text,
                options: [.reportProgress, .reportCompletion],
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            ) { result, flags, stop in
                // ICU invokes progress callbacks even while backtracking before its first match.
                if Task.isCancelled {
                    stop.pointee = true
                } else if flags.contains(.internalError) {
                    failed = true
                    stop.pointee = true
                } else if result != nil {
                    found = true
                    stop.pointee = true
                }
            }
            try Task.checkCancellation()
            if failed {
                throw OTodoError.validation(
                    field: "filterQuery",
                    message: "Regular expression evaluation failed; simplify the expression"
                )
            }
            return found
        }
    }

    private enum Token {
        case atom(Expression)
        case and, or, not, open, close, end
    }

    private struct Parser {
        private var lexer: Lexer
        private var token: Token

        init(_ source: String) throws {
            var lexer = Lexer(source)
            token = try lexer.next()
            self.lexer = lexer
        }

        mutating func parse() throws -> Expression {
            let expression = try parseOr(depth: 0)
            guard case .end = token else {
                throw lexer.error("Expected AND, OR, or the end of the query; use an explicit operator between expressions")
            }
            return expression
        }

        private mutating func advance() throws {
            token = try lexer.next()
        }

        private mutating func parseOr(depth: Int) throws -> Expression {
            let first = try parseAnd(depth: depth)
            guard case .or = token else { return first }
            var expressions = [first]
            while case .or = token {
                try advance()
                expressions.append(try parseAnd(depth: depth))
            }
            return .or(expressions)
        }

        private mutating func parseAnd(depth: Int) throws -> Expression {
            let first = try parseUnary(depth: depth)
            guard case .and = token else { return first }
            var expressions = [first]
            while case .and = token {
                try advance()
                expressions.append(try parseUnary(depth: depth))
            }
            return .and(expressions)
        }

        private mutating func parseUnary(depth: Int) throws -> Expression {
            guard depth < 64 else {
                throw lexer.error("Query nesting must be less than 64 levels; simplify parentheses or NOT expressions")
            }
            switch token {
            case .not:
                try advance()
                return .not(try parseUnary(depth: depth + 1))
            case .open:
                try advance()
                let expression = try parseOr(depth: depth + 1)
                guard case .close = token else {
                    throw lexer.error("Expected ')' to close the grouped expression")
                }
                try advance()
                return expression
            case let .atom(expression):
                try advance()
                return expression
            default:
                throw lexer.error("Expected a built-in filter, due:date, tag:value, project:value, name:/regex/, description:/regex/, NOT, or '('")
            }
        }
    }

    private struct Lexer {
        private let source: String.UnicodeScalarView
        private var index: String.UnicodeScalarView.Index

        init(_ source: String) {
            self.source = source.unicodeScalars
            index = self.source.startIndex
        }

        private var current: Unicode.Scalar? {
            index == source.endIndex ? nil : source[index]
        }

        @discardableResult
        private mutating func consume() -> Unicode.Scalar? {
            guard let scalar = current else { return nil }
            source.formIndex(after: &index)
            return scalar
        }

        func error(_ message: String) -> OTodoError {
            .validation(
                field: "filterQuery",
                message: "\(message) (at character \(source.distance(from: source.startIndex, to: index) + 1))"
            )
        }

        private func isBoundary(_ scalar: Unicode.Scalar) -> Bool {
            scalar.properties.isWhitespace || scalar == "(" || scalar == ")" || scalar == "&" || scalar == "|" || scalar == "!"
        }

        mutating func next() throws -> Token {
            while let scalar = current, scalar.properties.isWhitespace { consume() }
            guard let scalar = current else { return .end }
            switch scalar {
            case "&": consume(); return .and
            case "|": consume(); return .or
            case "!": consume(); return .not
            case "(": consume(); return .open
            case ")": consume(); return .close
            default: break
            }

            let start = index
            while let scalar = current, !isBoundary(scalar), scalar != ":" {
                consume()
            }
            let word = String(source[start..<index])
            if current == ":" {
                consume()
                switch word {
                case "tag": return .atom(.tag(try literal()))
                case "project": return .atom(.project(try literal()))
                case "due": return .atom(.due(try dueRange()))
                case "name": return .atom(.name(try regex()))
                case "description": return .atom(.description(try regex()))
                default: throw error("Unknown field '\(word)'; use due, tag, project, name, or description")
                }
            }
            switch word {
            case "all": return .atom(.all)
            case "active": return .atom(.active)
            case "today": return .atom(.today)
            case "overdue": return .atom(.overdue)
            case "tomorrow": return .atom(.tomorrow)
            case "next-seven-days": return .atom(.nextSevenDays)
            case "undated": return .atom(.undated)
            case "inbox": return .atom(.inbox)
            default:
                switch word.uppercased() {
                case "AND": return .and
                case "OR": return .or
                case "NOT": return .not
                default: throw error("Unknown expression '\(word)'; use a built-in filter or a supported field")
                }
            }
        }

        private mutating func dueRange() throws -> ClosedRange<CivilDate> {
            let value = try literal()
            let bounds = value.components(separatedBy: "..")
            guard bounds.count == 1 || bounds.count == 2 else {
                throw error("Expected due:YYYY-MM-DD or due:YYYY-MM-DD..YYYY-MM-DD")
            }
            let lower: CivilDate
            let upper: CivilDate
            do {
                lower = try CivilDate(rawValue: bounds[0])
                if bounds.count == 1 {
                    upper = lower
                } else {
                    upper = try CivilDate(rawValue: bounds[1])
                }
            } catch {
                throw self.error("Expected a valid Gregorian date in YYYY-MM-DD format")
            }
            guard lower <= upper else {
                throw error("Due date range must begin on or before its end")
            }
            return lower ... upper
        }

        private mutating func literal() throws -> String {
            if current == "\"" {
                consume()
                var value = ""
                while let scalar = consume() {
                    if scalar == "\"" {
                        guard !value.isEmpty else { throw error("Literal value must not be empty") }
                        try requireBoundary()
                        return value
                    }
                    if scalar == "\\" {
                        guard let escaped = consume(), escaped == "\"" || escaped == "\\" else {
                            throw error("Inside a quoted literal, escape only a double quote or a backslash")
                        }
                        value.unicodeScalars.append(escaped)
                    } else {
                        value.unicodeScalars.append(scalar)
                    }
                }
                throw error("Expected a closing double quote for the literal value")
            }

            let start = index
            while let scalar = current, !isBoundary(scalar) {
                guard scalar != "\"", scalar != "\\" else {
                    throw error("Use a double-quoted literal for quotes or backslashes")
                }
                consume()
            }
            guard start != index else { throw error("Expected a nonempty literal immediately after ':'") }
            return String(source[start..<index])
        }

        private mutating func regex() throws -> NSRegularExpression {
            guard consume() == "/" else { throw error("Expected a regular expression delimited by '/' immediately after ':'") }
            var pattern = ""
            while let scalar = consume() {
                if scalar == "/" {
                    var options: NSRegularExpression.Options = []
                    while let flag = current, !isBoundary(flag) {
                        switch flag {
                        case "i": options.insert(.caseInsensitive)
                        case "m": options.insert(.anchorsMatchLines)
                        case "s": options.insert(.dotMatchesLineSeparators)
                        default: throw error("Unsupported regex flag '\(flag)'; only i, m, and s are allowed")
                        }
                        consume()
                    }
                    do {
                        return try NSRegularExpression(pattern: pattern, options: options)
                    } catch {
                        throw self.error("Invalid regular expression: \(error.localizedDescription)")
                    }
                }
                if scalar == "\\" {
                    guard let escaped = consume() else { throw error("Expected a character after the regex escape and a closing '/'") }
                    // Only the query's delimiter escape is removed; ICU receives every other escape verbatim.
                    if escaped != "/" { pattern.unicodeScalars.append(scalar) }
                    pattern.unicodeScalars.append(escaped)
                } else {
                    pattern.unicodeScalars.append(scalar)
                }
            }
            throw error("Expected a closing '/' for the regular expression")
        }

        private func requireBoundary() throws {
            if let scalar = current, !isBoundary(scalar) {
                throw error("Expected an operator after the quoted literal")
            }
        }
    }
}
