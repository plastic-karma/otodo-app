import Foundation
import XCTest
@testable import OTodoCore

final class CodecTests: XCTestCase {
    func testStrictConfigurationParsesCanonicalDocument() throws {
        let configuration = try StrictStoreConfigCodec().parseConfiguration(canonicalConfiguration)
        let expected = try StoreConfiguration(
            schemaVersion: 1,
            tasksDirectory: "Tasks",
            projectsDirectory: "Projects",
            obsidianLinkPrefix: "Vault",
            defaultState: "open",
            states: [
                try WorkflowState(id: "open", name: "Open", isTerminal: false),
                try WorkflowState(id: "done", name: "Done", isTerminal: true),
            ]
        )

        XCTAssertEqual(configuration, expected)
    }

    func testUnsupportedConfigurationVersionTakesPrecedenceOverShapeValidation() {
        let source = [
            "schema_version = 2",
            "unknown_key = true",
        ].joined(separator: "\n")

        assertError(
            try StrictStoreConfigCodec().parseConfiguration(source),
            equals: .unsupportedSchema(found: 2, supported: 1)
        )
    }

    func testConfigurationRejectsUnknownTopLevelAndStateKeys() {
        let unknownTopLevel = canonicalConfiguration.replacingOccurrences(
            of: "default_state = \"open\"\n",
            with: "default_state = \"open\"\nunknown_key = true\n"
        )
        assertValidation(
            try StrictStoreConfigCodec().parseConfiguration(unknownTopLevel),
            field: "unknown_key"
        )

        let unknownState = canonicalConfiguration + "color = \"green\"\n"
        assertValidation(
            try StrictStoreConfigCodec().parseConfiguration(unknownState),
            field: "states[1].color"
        )
    }

    func testConfigurationRejectsLeadingZeroSchemaVersion() {
        let source = canonicalConfiguration.replacingOccurrences(
            of: "schema_version = 1",
            with: "schema_version = 01"
        )

        assertValidation(
            try StrictStoreConfigCodec().parseConfiguration(source),
            field: "schema_version"
        )
    }

    func testStructuralSchemaLoadsAuthoritativeBundledDocument() throws {
        let source = try StrictStoreConfigCodec.structuralSchemaJSON()
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any]
        )

        XCTAssertEqual(root["$schema"] as? String, "https://json-schema.org/draft/2020-12/schema")
        XCTAssertEqual(root["$id"] as? String, "https://obsidian-todo.local/schema/v1")
        XCTAssertEqual(root["x-obsidian-todo-schema-version"] as? Int, 1)

        let definitions = try XCTUnwrap(root["$defs"] as? [String: Any])
        let task = try XCTUnwrap(definitions["task"] as? [String: Any])
        XCTAssertEqual(
            task["required"] as? [String],
            ["name", "state", "projects", "tags"]
        )
        XCTAssertEqual(task["additionalProperties"] as? Bool, true)

        let properties = try XCTUnwrap(task["properties"] as? [String: Any])
        XCTAssertNotNil(properties["last_completed_date"])
        let recurrenceFrom = try XCTUnwrap(properties["recurrence_from"] as? [String: Any])
        XCTAssertEqual(recurrenceFrom["enum"] as? [String], ["schedule", "completion"])
    }

    func testMinimalTaskSerializationIsExact() throws {
        let task = try TodoTask(
            id: taskID,
            relativePath: taskPath,
            name: "Minimal task",
            state: "open",
            projectSlugs: [],
            tags: [],
            dueDate: nil,
            recurrence: nil,
            recurrenceFrom: nil,
            lastCompletedDate: nil,
            body: "",
            extraProperties: []
        )

        let serialized = try ObsidianTaskCodec().serializeTask(task, configuration: configuration)
        let expected = [
            "---",
            "name: \"Minimal task\"",
            "state: open",
            "projects: []",
            "tags: []",
            "---",
            "",
        ].joined(separator: "\n")

        XCTAssertEqual(Data(serialized.utf8), Data(expected.utf8))
    }

    func testCRLFFrontMatterPreservesBodyBytesExactlyAcrossMetadataEdit() throws {
        let body = "First line\r\n\r\nSecond line\nFinal line without newline"
        let source = [
            "---",
            "name: Original",
            "state: open",
            "projects: []",
            "tags: []",
            "---",
        ].joined(separator: "\r\n") + "\r\n" + body

        var task = try codec.parseTask(
            id: taskID,
            relativePath: taskPath,
            text: source,
            configuration: configuration
        )
        XCTAssertEqual(Data(task.body.utf8), Data(body.utf8))

        task.name = "Renamed"
        let serialized = try codec.serializeTask(task, configuration: configuration)
        let expected = [
            "---",
            "name: \"Renamed\"",
            "state: open",
            "projects: []",
            "tags: []",
            "---",
        ].joined(separator: "\n") + "\n" + body
        XCTAssertEqual(Data(serialized.utf8), Data(expected.utf8))
    }

    func testUnknownNestedYAMLRoundTripsSemantically() throws {
        let source = taskRecord(additionalLines: [
            "plugin:",
            "  enabled: true",
            "  options:",
            "    - yes",
            "    - 7",
            "    - null",
            "  nested:",
            "    child: value",
        ])
        let expected = YAMLProperty(
            name: "plugin",
            value: .mapping([
                YAMLProperty(name: "enabled", value: .bool(true)),
                YAMLProperty(
                    name: "options",
                    value: .sequence([.string("yes"), .integer(7), .null])
                ),
                YAMLProperty(
                    name: "nested",
                    value: .mapping([YAMLProperty(name: "child", value: .string("value"))])
                ),
            ])
        )

        let parsed = try codec.parseTask(
            id: taskID,
            relativePath: taskPath,
            text: source,
            configuration: configuration
        )
        XCTAssertEqual(parsed.extraProperties, [expected])

        let serialized = try codec.serializeTask(parsed, configuration: configuration)
        let reparsed = try codec.parseTask(
            id: taskID,
            relativePath: taskPath,
            text: serialized,
            configuration: configuration
        )
        XCTAssertEqual(reparsed.extraProperties, [expected])
    }

    func testYAML12YesScalarRemainsAString() throws {
        let parsed = try codec.parseTask(
            id: taskID,
            relativePath: taskPath,
            text: taskRecord(additionalLines: ["plugin: yes"]),
            configuration: configuration
        )

        XCTAssertEqual(parsed.extraProperties, [YAMLProperty(name: "plugin", value: .string("yes"))])
        let serialized = try codec.serializeTask(parsed, configuration: configuration)
        XCTAssertTrue(serialized.contains("\nplugin: \"yes\"\n"))
    }

    func testDuplicateTopLevelAndNestedYAMLKeysAreRejected() {
        assertTypedValidationFailure(
            try codec.parseTask(
                id: taskID,
                relativePath: taskPath,
                text: taskRecord(additionalLines: ["name: Duplicate"]),
                configuration: configuration
            )
        )

        assertTypedValidationFailure(
            try codec.parseTask(
                id: taskID,
                relativePath: taskPath,
                text: taskRecord(additionalLines: [
                    "plugin:",
                    "  child: first",
                    "  child: second",
                ]),
                configuration: configuration
            )
        )
    }

    func testExplicitYAMLTagsAreRejectedForEveryNodeKind() {
        let taggedRecords = [
            taskRecord().replacingOccurrences(of: "name: Task", with: "name: !!str Task"),
            taskRecord(additionalLines: ["plugin: !!seq []"]),
            taskRecord(additionalLines: ["plugin: !!map {}"]),
        ]

        for source in taggedRecords {
            assertValidation(
                try codec.parseTask(
                    id: taskID,
                    relativePath: taskPath,
                    text: source,
                    configuration: configuration
                ),
                field: "frontMatter"
            )
        }
    }

    func testYAMLAnchorsAndAliasesAreRejectedIndependently() {
        for property in ["plugin: &item value", "plugin: *item"] {
            assertValidation(
                try codec.parseTask(
                    id: taskID,
                    relativePath: taskPath,
                    text: taskRecord(additionalLines: [property]),
                    configuration: configuration
                ),
                field: "frontMatter"
            )
        }
    }

    func testPlainAndQuotedYAMLMergeKeysAreRejected() {
        for mergeKey in ["<<", "\"<<\""] {
            assertValidation(
                try codec.parseTask(
                    id: taskID,
                    relativePath: taskPath,
                    text: taskRecord(additionalLines: [
                        "plugin:",
                        "  \(mergeKey): { enabled: true }",
                    ]),
                    configuration: configuration
                ),
                field: "frontMatter"
            )
        }
    }

    func testEveryConflictMarkerIsRejectedAsAConflict() {
        for marker in ["<<<<<<<", "|||||||", "=======", ">>>>>>>"] {
            assertError(
                try codec.parseTask(
                    id: taskID,
                    relativePath: taskPath,
                    text: taskRecord(body: "Before\n\(marker) branch\nAfter"),
                    configuration: configuration
                ),
                equals: .conflict(message: "Markdown record contains an unresolved conflict marker")
            )
        }
    }

    func testExcessiveFlowDepthReturnsTypedValidationInsteadOfEnteringYAMLParser() {
        let depth = 10_000
        let value = String(repeating: "[", count: depth) + "null" +
            String(repeating: "]", count: depth)

        assertValidation(
            try codec.parseTask(
                id: taskID,
                relativePath: taskPath,
                text: taskRecord(additionalLines: ["plugin: \(value)"]),
                configuration: configuration
            ),
            field: "frontMatter",
            message: "YAML front matter exceeds the supported nesting depth"
        )
    }

    func testTaskCodecParsesAndSerializesCanonicalProjectsTagsDatesAndRecurrence() throws {
        let source = taskRecord(
            name: "Canonical task",
            projects: ["[[Vault/Projects/zeta]]", "[[Vault/Projects/alpha]]"],
            tags: ["zeta", "alpha"],
            additionalLines: [
                "due_date: 2026-01-06",
                "recurrence: \"byday=TU,MO;interval=2;freq=weekly\"",
                "recurrence_from: completion",
                "last_completed_date: 2025-12-23",
            ],
            body: "Body"
        )

        let task = try codec.parseTask(
            id: taskID,
            relativePath: taskPath,
            text: source,
            configuration: configuration
        )
        XCTAssertEqual(task.projectSlugs, ["zeta", "alpha"])
        XCTAssertEqual(task.tags, ["zeta", "alpha"])
        XCTAssertEqual(task.dueDate, try CivilDate(rawValue: "2026-01-06"))
        XCTAssertEqual(task.recurrence, "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TU")
        XCTAssertEqual(task.recurrenceFrom, .completion)
        XCTAssertEqual(task.lastCompletedDate, try CivilDate(rawValue: "2025-12-23"))

        let serialized = try codec.serializeTask(task, configuration: configuration)
        let expected = [
            "---",
            "name: \"Canonical task\"",
            "state: open",
            "projects:",
            "  - \"[[Vault/Projects/alpha]]\"",
            "  - \"[[Vault/Projects/zeta]]\"",
            "tags:",
            "  - \"alpha\"",
            "  - \"zeta\"",
            "due_date: 2026-01-06",
            "recurrence: \"FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TU\"",
            "recurrence_from: completion",
            "last_completed_date: 2025-12-23",
            "---",
            "Body",
        ].joined(separator: "\n")
        XCTAssertEqual(Data(serialized.utf8), Data(expected.utf8))
    }

    func testTaskCodecRejectsUnconfiguredState() {
        assertValidation(
            try codec.parseTask(
                id: taskID,
                relativePath: taskPath,
                text: taskRecord(state: "blocked"),
                configuration: configuration
            ),
            field: "state"
        )
    }

    func testTaskCodecRejectsNoncanonicalProjectLink() {
        assertValidation(
            try codec.parseTask(
                id: taskID,
                relativePath: taskPath,
                text: taskRecord(projects: ["[[Projects/alpha]]"]),
                configuration: configuration
            ),
            field: "projects"
        )
    }

    func testTaskCodecRejectsInvalidDate() {
        assertValidation(
            try codec.parseTask(
                id: taskID,
                relativePath: taskPath,
                text: taskRecord(additionalLines: ["due_date: 2025-02-29"]),
                configuration: configuration
            ),
            field: "due_date"
        )
    }

    func testTaskCodecRejectsInvalidRecurrence() {
        assertValidation(
            try codec.parseTask(
                id: taskID,
                relativePath: taskPath,
                text: taskRecord(additionalLines: [
                    "due_date: 2026-01-06",
                    "recurrence: \"FREQ=HOURLY\"",
                    "recurrence_from: schedule",
                ]),
                configuration: configuration
            ),
            field: "recurrence"
        )
    }

    private var codec: ObsidianTaskCodec { ObsidianTaskCodec() }

    private var taskID: TaskID {
        get throws { try TaskID(rawValue: "01ARZ3NDEKTSV4RRFFQ69G5FAV") }
    }

    private var taskPath: String { "Tasks/01ARZ3NDEKTSV4RRFFQ69G5FAV.md" }

    private var configuration: StoreConfiguration {
        get throws { try StrictStoreConfigCodec().parseConfiguration(canonicalConfiguration) }
    }

    private var canonicalConfiguration: String {
        [
            "schema_version = 1",
            "tasks_directory = \"Tasks\"",
            "projects_directory = \"Projects\"",
            "obsidian_link_prefix = \"Vault\"",
            "default_state = \"open\"",
            "",
            "[[states]]",
            "id = \"open\"",
            "name = \"Open\"",
            "terminal = false",
            "",
            "[[states]]",
            "id = \"done\"",
            "name = \"Done\"",
            "terminal = true",
            "",
        ].joined(separator: "\n")
    }

    private func taskRecord(
        name: String = "Task",
        state: String = "open",
        projects: [String] = [],
        tags: [String] = [],
        additionalLines: [String] = [],
        body: String = ""
    ) -> String {
        var lines = ["---", "name: \(name)", "state: \(state)"]
        if projects.isEmpty {
            lines.append("projects: []")
        } else {
            lines.append("projects:")
            lines.append(contentsOf: projects.map { "  - \"\($0)\"" })
        }
        if tags.isEmpty {
            lines.append("tags: []")
        } else {
            lines.append("tags:")
            lines.append(contentsOf: tags.map { "  - \"\($0)\"" })
        }
        lines.append(contentsOf: additionalLines)
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + body
    }

    private func assertTypedValidationFailure<T>(
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try expression()
            XCTFail("Expected validation failure", file: file, line: line)
        } catch let error as OTodoError {
            guard case .validation = error else {
                XCTFail("Expected validation failure, got \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("Expected OTodoError, got \(error)", file: file, line: line)
        }
    }

    private func assertValidation<T>(
        _ expression: @autoclosure () throws -> T,
        field expectedField: String,
        message expectedMessage: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try expression()
            XCTFail("Expected validation failure", file: file, line: line)
        } catch let error as OTodoError {
            guard case let .validation(field, message) = error else {
                XCTFail("Expected validation failure, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(field, expectedField, file: file, line: line)
            if let expectedMessage {
                XCTAssertEqual(message, expectedMessage, file: file, line: line)
            }
        } catch {
            XCTFail("Expected OTodoError, got \(error)", file: file, line: line)
        }
    }

    private func assertError<T>(
        _ expression: @autoclosure () throws -> T,
        equals expected: OTodoError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try expression()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as OTodoError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected OTodoError, got \(error)", file: file, line: line)
        }
    }
}
