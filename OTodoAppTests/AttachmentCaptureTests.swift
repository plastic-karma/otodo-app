import Foundation
import OTodoCore
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import OTodo

@MainActor
final class AttachmentCaptureTests: XCTestCase {
    func testProviderFileIsCopiedBeforeCallbackReturnsAndSurvivesSourceRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("résumé.pdf")
        let original = Data([0, 255, 128, 13, 10, 1])
        try original.write(to: source)
        let provider = NSItemProvider()
        provider.suggestedName = "résumé.pdf"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            return nil
        }
        let item = NSExtensionItem()
        item.attachments = [provider]
        let capture = try await ShareCaptureExtractor.extract([item])
        defer { capture.cleanTemporaryFiles() }
        XCTAssertEqual(capture.files.count, 1)
        XCTAssertEqual(capture.name, "résumé.pdf")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(capture.files.first)), original)
    }

    func testSharedFileURLBecomesBinaryAttachmentInsteadOfSourceURL() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("Keep these bytes\r\n".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)]
        let capture = try await ShareCaptureExtractor.extract([item])
        defer { capture.cleanTemporaryFiles() }
        XCTAssertEqual(capture.files.count, 1)
        XCTAssertFalse(capture.body.contains("file://"))
        XCTAssertNil(capture.url)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(capture.files.first)), Data("Keep these bytes\r\n".utf8))
    }

    func testOversizedShareFailsAndDoesNotCreateACapture() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data(repeating: 1, count: AttachmentLinks.maximumBytes + 1).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)]
        do {
            let capture = try await ShareCaptureExtractor.extract([item])
            capture.cleanTemporaryFiles()
            XCTFail("Oversized files must be rejected before capture")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("20 MiB"))
        }
    }

    func testSharedSaveCommitsBytesAndCleanupCannotDeleteThem() async throws {
        let directory = try SharedWorkspaceStorage.prepareForApplication(isUITesting: true)
        let selections = RepositorySelectionStore(directoryURL: directory)
        let previous = try await selections.load()
        let selection = try RepositorySelection(owner: "attachment-testing", name: UUID().uuidString, branch: "main", storePath: "Todo")
        let root = directory.appendingPathComponent("workspaces")
        let persistence = FileWorkspaceStore(rootURL: root)
        addTeardownBlock {
            if let previous { try await selections.save(previous) } else { try await selections.clear() }
            try? FileManager.default.removeItem(at: root.appendingPathComponent("\(FileWorkspaceStore.selectionKey(for: selection)).json"))
            try? FileManager.default.removeItem(at: root.appendingPathComponent("attachment-files/\(FileWorkspaceStore.selectionKey(for: selection))"))
            _ = try SharedWorkspaceStorage.prepareForApplication(isUITesting: false)
        }
        let configuration = try StoreConfiguration(schemaVersion: 1, tasksDirectory: "Tasks", projectsDirectory: "Projects",
            obsidianLinkPrefix: "", defaultState: "todo", states: [try WorkflowState(id: "todo", name: "Todo", isTerminal: false)])
        try await persistence.save(WorkspaceState(selection: selection, configuration: configuration, knownProjectSlugs: [],
            tasks: [], baseHeadCommitSHA: "head", baseRootTreeSHA: "tree", pendingChanges: [], conflicts: []), expectedRevision: nil)
        try await selections.save(selection)
        let context = try await SharedTaskCapture.attachmentContext()
        let bytes = Data([0, 128, 255, 0, 10])
        let draft = try await context.store.stage(data: bytes, filename: "original.bin", selection: selection)
        let task = try await SharedTaskCapture.save(name: "Shared binary", body: "Source", attachments: [draft], expectedSelection: selection)
        try await context.store.discard(drafts: [draft], selection: selection, persistence: persistence)
        let survivingBytes = try await context.store.read(draft.localFile, selection: selection)
        XCTAssertEqual(survivingBytes, bytes)
        XCTAssertEqual(AttachmentLinks.references(body: task.body, taskPath: task.relativePath).map(\.path), [draft.path])
        let saved = try await persistence.load(selection: selection)
        XCTAssertEqual(saved?.pendingChanges.count, 2)
        XCTAssertEqual(saved?.pendingChanges.filter { $0.payload.binaryFile != nil }.count, 1)
    }
}
