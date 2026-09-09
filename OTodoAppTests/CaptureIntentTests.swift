import Foundation
import OTodoCore
import UIKit
import XCTest
@testable import OTodo

@MainActor
final class CaptureIntentTests: XCTestCase {
    func testSharedTextFindsFirstWebLinkWithoutProsePunctuation() async throws {
        let text = "Read https://example.com/guide?q=one%20two#notes, then https://example.org/later."
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: text)
        let capture = try await ShareCaptureExtractor.extract([item])
        XCTAssertEqual(capture.url, "https://example.com/guide?q=one%20two#notes")
        XCTAssertEqual(capture.body, text)
    }

    func testExplicitSourceLinkWinsAcrossItemsWithoutDiscardingText() async throws {
        let text = NSExtensionItem()
        text.attributedContentText = NSAttributedString(string: "Quoted https://example.com/other")
        let source = NSExtensionItem()
        let url = try XCTUnwrap(URL(string: "https://example.com/source?q=one#section"))
        source.attachments = [NSItemProvider(item: url as NSURL, typeIdentifier: "public.url")]
        let capture = try await ShareCaptureExtractor.extract([text, source])
        XCTAssertEqual(capture.url, url.absoluteString)
        XCTAssertTrue(capture.body.contains("Quoted https://example.com/other"))
        XCTAssertTrue(capture.body.contains(url.absoluteString))
    }

    func testNonWebLinksRemainContextWithoutBecomingTaskLinks() async throws {
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: "Contact me@example.com")
        let url = try XCTUnwrap(URL(string: "obsidian://open?vault=Notes&file=Review"))
        item.attachments = [NSItemProvider(item: url as NSURL, typeIdentifier: "public.url")]
        let capture = try await ShareCaptureExtractor.extract([item])
        XCTAssertNil(capture.url)
        XCTAssertTrue(capture.body.contains(url.absoluteString))
        XCTAssertTrue(capture.body.contains("me@example.com"))
    }

    func testParameterizedIntentPersistsProjectlessUndatedMarkdownInNormalOutbox() async throws {
        let directory = try SharedWorkspaceStorage.prepareForApplication(isUITesting: true)
        let selectionStore = RepositorySelectionStore(directoryURL: directory)
        let previousSelection = try await selectionStore.load()
        let selection = try RepositorySelection(
            owner: "intent-testing", name: UUID().uuidString, branch: "main", storePath: ""
        )
        let root = directory.appendingPathComponent("workspaces", isDirectory: true)
        addTeardownBlock {
            if let previousSelection {
                try await selectionStore.save(previousSelection)
            } else {
                try await selectionStore.clear()
            }
            let file = root.appendingPathComponent("\(FileWorkspaceStore.selectionKey(for: selection)).json")
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            _ = try SharedWorkspaceStorage.prepareForApplication(isUITesting: false)
        }
        let configuration = try StoreConfiguration(
            schemaVersion: 1, tasksDirectory: "todos", projectsDirectory: "projects",
            obsidianLinkPrefix: "", defaultState: "todo",
            states: [
                try WorkflowState(id: "todo", name: "Pending", isTerminal: false),
                try WorkflowState(id: "done", name: "Done", isTerminal: true),
            ]
        )
        try await FileWorkspaceStore(rootURL: root).save(
            WorkspaceState(
                selection: selection, configuration: configuration, knownProjectSlugs: [],
                tasks: [], baseHeadCommitSHA: "connected-head", baseRootTreeSHA: "connected-tree",
                pendingChanges: [], conflicts: []
            ),
            expectedRevision: nil
        )
        try await selectionStore.save(selection)

        var intent = AddTodoIntent()
        intent.text = "Review next Tue at 14:30\nKeep the original Markdown context."
        intent.sourceURL = try XCTUnwrap(URL(string: "https://example.com/review?source=shortcut#notes"))
        _ = try await intent.perform()

        let service = TaskWorkspaceService(
            persistence: FileWorkspaceStore(rootURL: root), taskCodec: ObsidianTaskCodec()
        )
        let saved = try await service.loadWorkspace(selection: selection)
        let document = try XCTUnwrap(saved.tasks.first)
        XCTAssertEqual(document.task.name, "Review next Tue at 14:30")
        XCTAssertTrue(document.task.body.contains(intent.text))
        XCTAssertTrue(document.task.body.contains(try XCTUnwrap(intent.sourceURL).absoluteString))
        XCTAssertTrue(document.task.projectSlugs.isEmpty)
        XCTAssertNil(document.task.dueDate)
        XCTAssertNil(document.task.dueTime)
        XCTAssertTrue(try TaskFilterQuery.inbox.matches(
            document.task, terminalStateIDs: ["done"], dates: TaskDateContext()
        ))
        XCTAssertEqual(saved.pendingChanges.count, 1)
        XCTAssertEqual(saved.pendingChanges.first?.content, document.content)

        let source = NSExtensionItem()
        source.attributedTitle = NSAttributedString(string: "Shared source")
        source.attributedContentText = NSAttributedString(string: "Selected source context")
        let text = "Capture these notes\n- Keep **Markdown** intact."
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first?q=source#part"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second"))
        let pageURL = "https://example.com/page#selection"
        let page: NSDictionary = [
            NSExtensionJavaScriptPreprocessingResultsKey: [
                "title": "Safari source today at 3 pm", "url": pageURL, "selection": "Selected in Safari",
            ],
        ]
        source.attachments = [
            NSItemProvider(item: text as NSString, typeIdentifier: "public.plain-text"),
            NSItemProvider(item: firstURL as NSURL, typeIdentifier: "public.url"),
            NSItemProvider(item: secondURL as NSURL, typeIdentifier: "public.url"),
            NSItemProvider(item: page, typeIdentifier: "com.apple.property-list"),
        ]
        let anotherSource = NSExtensionItem()
        anotherSource.attachments = [
            NSItemProvider(item: "Another selected passage" as NSString, typeIdentifier: "public.plain-text"),
        ]
        let capture = try await ShareCaptureExtractor.extract([source, anotherSource])
        let sharedTask = try await SharedTaskCapture.save(name: capture.name, body: capture.body, url: capture.url)
        let afterSharing = try await service.loadWorkspace(selection: selection)
        let sharedDocument = try XCTUnwrap(afterSharing.tasks.first(where: { $0.task.id == sharedTask.id }))
        XCTAssertEqual(sharedDocument.task.name, "Safari source today at 3 pm")
        XCTAssertEqual(sharedDocument.task.url, firstURL.absoluteString)
        for context in [text, "Shared source", "Selected source context", firstURL.absoluteString, secondURL.absoluteString, pageURL, "Selected in Safari", "Another selected passage"] {
            XCTAssertTrue(sharedDocument.task.body.contains(context), "Shared context must not be dropped")
        }
        XCTAssertTrue(sharedDocument.task.projectSlugs.isEmpty)
        XCTAssertNil(sharedDocument.task.dueDate)
        XCTAssertNil(sharedDocument.task.dueTime)
        XCTAssertEqual(afterSharing.pendingChanges.count, 2)
        XCTAssertEqual(
            afterSharing.pendingChanges.first(where: { $0.path == sharedDocument.task.relativePath })?.content,
            sharedDocument.content
        )

        try await selectionStore.clear()
        do {
            _ = try await intent.perform()
            XCTFail("Capture must not report success without a connected workspace")
        } catch let error as OTodoError {
            guard case .validation(field: "workspace", message: _) = error else { throw error }
        }
        let afterRejectedCapture = try await service.loadWorkspace(selection: selection)
        XCTAssertEqual(afterRejectedCapture, afterSharing)
    }

    func testIntentAndSharedCaptureRemainRootsInVersionTwoHierarchy() async throws {
        let directory = try SharedWorkspaceStorage.prepareForApplication(isUITesting: true)
        let selectionStore = RepositorySelectionStore(directoryURL: directory)
        let previousSelection = try await selectionStore.load()
        let selection = try RepositorySelection(
            owner: "subtask-capture-testing", name: UUID().uuidString, branch: "main", storePath: ""
        )
        let root = directory.appendingPathComponent("workspaces", isDirectory: true)
        addTeardownBlock {
            if let previousSelection {
                try await selectionStore.save(previousSelection)
            } else {
                try await selectionStore.clear()
            }
            let file = root.appendingPathComponent("\(FileWorkspaceStore.selectionKey(for: selection)).json")
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            _ = try SharedWorkspaceStorage.prepareForApplication(isUITesting: false)
        }
        let configuration = try StoreConfiguration(
            schemaVersion: 2, tasksDirectory: "todos", projectsDirectory: "projects",
            obsidianLinkPrefix: "", defaultState: "todo",
            states: [
                try WorkflowState(id: "todo", name: "Pending", isTerminal: false),
                try WorkflowState(id: "done", name: "Done", isTerminal: true),
            ]
        )
        let persistence = FileWorkspaceStore(rootURL: root)
        try await persistence.save(
            WorkspaceState(
                selection: selection, configuration: configuration, knownProjectSlugs: [],
                tasks: [], baseHeadCommitSHA: "connected-head", baseRootTreeSHA: "connected-tree",
                pendingChanges: [], conflicts: []
            ), expectedRevision: nil
        )
        try await selectionStore.save(selection)
        let service = TaskWorkspaceService(persistence: persistence, taskCodec: ObsidianTaskCodec())
        let parent = try await service.addTask(selection: selection, name: "Existing terminal parent", state: "done")
        let child = try await service.addTask(selection: selection, name: "Existing child", parentID: parent.id)

        var intent = AddTodoIntent()
        intent.text = "Root from Shortcut"
        _ = try await intent.perform()
        let shared = try await SharedTaskCapture.save(name: "Root from Share", body: "Source context")
        let restored = try await TaskWorkspaceService(
            persistence: FileWorkspaceStore(rootURL: root), taskCodec: ObsidianTaskCodec()
        ).loadWorkspace(selection: selection)
        let shortcut = try XCTUnwrap(restored.tasks.first { $0.task.name == "Root from Shortcut" }?.task)
        let share = try XCTUnwrap(restored.tasks.first { $0.task.id == shared.id }?.task)
        for task in [shortcut, share] {
            XCTAssertNil(task.parentID)
            XCTAssertTrue(try TaskFilterQuery.inbox.matches(
                task, terminalStateIDs: ["done"], dates: TaskDateContext()
            ))
        }
        XCTAssertEqual(restored.tasks.first { $0.task.id == child.id }?.task.parentID, parent.id)
        XCTAssertEqual(restored.tasks.first { $0.task.id == parent.id }?.task.state, "done")
        XCTAssertEqual(share.body, "Source context")
    }
}
