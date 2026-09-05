import Foundation
import XCTest
@testable import OTodoCore

final class TaskFilterStoreTests: XCTestCase, @unchecked Sendable {
    func testCustomQueryAndStarsSurviveRecreationEditingAndDeletion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try self.selection()
        let store = FileTaskFilterStore(rootURL: directory)
        let custom = try SavedTaskFilter(
            name: "Release work",
            query: #"active AND (tag:release OR project:"client app") AND NOT name:/draft/i"#,
            isStarred: true
        )
        var filters = SavedTaskFilter.defaults
        filters[0] = try SavedTaskFilter(id: "today", name: "Today", query: "today", isStarred: false)
        filters.append(custom)
        try await store.save(filters, selection: selection)

        let recreated = FileTaskFilterStore(rootURL: directory)
        let restored = try await recreated.load(selection: selection)
        XCTAssertEqual(restored, filters)

        let edited = try SavedTaskFilter(
            id: custom.id,
            name: "Ready to ship",
            query: "tag:release AND NOT project:paused",
            isStarred: false
        )
        filters[3] = edited
        try await recreated.save(filters, selection: selection)
        let afterEdit = try await FileTaskFilterStore(rootURL: directory).load(selection: selection)
        XCTAssertEqual(afterEdit, filters)

        filters.removeLast()
        try await recreated.save(filters, selection: selection)
        let afterDelete = try await FileTaskFilterStore(rootURL: directory).load(selection: selection)
        XCTAssertEqual(afterDelete, filters)
    }

    func testRepositoryBranchAndStorePathHaveIndependentLibraries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileTaskFilterStore(rootURL: directory)
        let original = try selection()
        let selections = [
            original,
            try selection(owner: "another-owner"),
            try selection(name: "another-repository"),
            try selection(branch: "work/filters"),
            try selection(storePath: "personal/tasks"),
        ]
        var expected: [[SavedTaskFilter]] = []
        for (index, selection) in selections.enumerated() {
            let initiallyLoaded = try await store.load(selection: selection)
            XCTAssertEqual(initiallyLoaded, SavedTaskFilter.defaults)
            let filters = SavedTaskFilter.defaults + [try SavedTaskFilter(
                name: "Workspace \(index)", query: "tag:workspace-\(index)", isStarred: true
            )]
            try await store.save(filters, selection: selection)
            expected.append(filters)
        }
        let recreated = FileTaskFilterStore(rootURL: directory)
        for (selection, filters) in zip(selections, expected) {
            let actual = try await recreated.load(selection: selection)
            XCTAssertEqual(actual, filters)
        }
        let normalizedSelection = try selection(storePath: "/tasks/")
        let normalized = try await recreated.load(selection: normalizedSelection)
        XCTAssertEqual(normalized, expected[0])
    }

    func testRejectedMissingBuiltinAndDuplicateIDsLeaveSavedStateUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try self.selection()
        let store = FileTaskFilterStore(rootURL: directory)
        let custom = try SavedTaskFilter(name: "Work", query: "tag:work", isStarred: true)
        let original = SavedTaskFilter.defaults + [custom]
        try await store.save(original, selection: selection)
        let originalBytes = try Data(contentsOf: fileURL(directory, selection))

        for invalid in [Array(original.dropFirst()), original + [custom]] {
            do {
                try await store.save(invalid, selection: selection)
                XCTFail("Expected invalid collection to be rejected")
            } catch let error as OTodoError {
                guard case .validation = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: fileURL(directory, selection)), originalBytes)
            let restored = try await FileTaskFilterStore(rootURL: directory).load(selection: selection)
            XCTAssertEqual(restored, original)
        }
    }

    func testBuiltinDefinitionsAndUnsafeCustomRecordsCannotBeCreatedOrDecoded() throws {
        XCTAssertThrowsError(try SavedTaskFilter(id: "today", name: "Renamed", query: "today", isStarred: true))
        XCTAssertThrowsError(try SavedTaskFilter(id: "active", name: "Active", query: "all", isStarred: true))
        XCTAssertThrowsError(try SavedTaskFilter(id: "../escape", name: "Work", query: "all", isStarred: false))
        XCTAssertThrowsError(try SavedTaskFilter(name: " \n ", query: "all", isStarred: false))
        XCTAssertThrowsError(try SavedTaskFilter(name: "Work\nHome", query: "all", isStarred: false))
        XCTAssertThrowsError(try SavedTaskFilter(name: "Work", query: "tag:", isStarred: false))

        let forged = Data(#"{"id":"all","name":"All","query":"active","isStarred":false}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SavedTaskFilter.self, from: forged))
    }

    func testCorruptDataIsNeitherHiddenByDefaultsNorOverwritten() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try self.selection()
        let url = fileURL(directory, selection)
        let corrupt = Data("{ interrupted filter file".utf8)
        try corrupt.write(to: url)
        let store = FileTaskFilterStore(rootURL: directory)

        await assertCorrupt { _ = try await store.load(selection: selection) }
        await assertCorrupt { try await store.save(SavedTaskFilter.defaults, selection: selection) }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testInvalidPersistedEnvelopesCannotBeLoadedOrReplaced() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = try self.selection()
        let store = FileTaskFilterStore(rootURL: directory)
        try await store.save(SavedTaskFilter.defaults, selection: selection)
        let url = fileURL(directory, selection)
        let valid = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var unsupported = valid
        unsupported["version"] = 99
        var mismatched = valid
        var foreignSelection = try XCTUnwrap(valid["selection"] as? [String: Any])
        foreignSelection["branch"] = "different"
        mismatched["selection"] = foreignSelection
        var missingBuiltin = valid
        let builtinRecords = try XCTUnwrap(valid["filters"] as? [[String: Any]])
        missingBuiltin["filters"] = Array(builtinRecords.dropFirst())
        var invalidQuery = valid
        invalidQuery["filters"] = builtinRecords + [[
            "id": "custom", "name": "Invalid", "query": "tag:", "isStarred": true,
        ]]

        for envelope in [unsupported, mismatched, missingBuiltin, invalidQuery] {
            let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            try bytes.write(to: url)
            await assertCorrupt { _ = try await store.load(selection: selection) }
            await assertCorrupt { try await store.save(SavedTaskFilter.defaults, selection: selection) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testUnavailableRootReportsFailureAndRetainsLastSavedLibrary() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("filters", isDirectory: true)
        let backup = directory.appendingPathComponent("unavailable-filters", isDirectory: true)
        let selection = try self.selection()
        let store = FileTaskFilterStore(rootURL: root)
        let original = SavedTaskFilter.defaults + [try SavedTaskFilter(
            name: "Keep me", query: "project:retained", isStarred: true
        )]
        try await store.save(original, selection: selection)
        try FileManager.default.moveItem(at: root, to: backup)
        let obstruction = Data("Storage is unavailable".utf8)
        try obstruction.write(to: root)

        await assertCorrupt { try await store.save(SavedTaskFilter.defaults, selection: selection) }
        XCTAssertEqual(try Data(contentsOf: root), obstruction)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: backup, to: root)
        let restored = try await FileTaskFilterStore(rootURL: root).load(selection: selection)
        XCTAssertEqual(restored, original)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func selection(
        owner: String = "owner",
        name: String = "repository",
        branch: String = "main",
        storePath: String = "tasks"
    ) throws -> RepositorySelection {
        try RepositorySelection(owner: owner, name: name, branch: branch, storePath: storePath)
    }

    private func fileURL(_ directory: URL, _ selection: RepositorySelection) -> URL {
        directory.appendingPathComponent("\(FileWorkspaceStore.selectionKey(for: selection)).json")
    }

    private func assertCorrupt(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected corruptLocalState")
        } catch let error as OTodoError {
            guard case .corruptLocalState = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
