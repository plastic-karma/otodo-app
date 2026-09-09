import Foundation
import OTodoCore

/// Capture returns only after the normal Markdown workspace/outbox transaction succeeds.
enum SharedTaskCapture {
    struct AttachmentContext: Sendable {
        let selection: RepositorySelection
        let store: AttachmentStore
        let persistence: FileWorkspaceStore
    }

    static func attachmentContext() async throws -> AttachmentContext {
        let directory = try SharedWorkspaceStorage.directoryURL()
        let selectionStore = RepositorySelectionStore(directoryURL: directory)
        guard let selection = try await selectionStore.load() else {
            throw OTodoError.validation(field: "workspace", message: "Open OTodo and connect a workspace before capturing todos.")
        }
        let root = directory.appendingPathComponent("workspaces", isDirectory: true)
        return AttachmentContext(selection: selection, store: AttachmentStore(rootURL: root),
                                 persistence: FileWorkspaceStore(rootURL: root))
    }

    static func save(name: String, body: String, url: String? = nil, attachments: [AttachmentDraft] = [],
                     expectedSelection: RepositorySelection? = nil) async throws -> TodoTask {
        let context = try await attachmentContext()
        if let expectedSelection, expectedSelection != context.selection {
            throw OTodoError.validation(field: "workspace", message: "The selected workspace changed. Cancel and share again.")
        }
        let service = TaskWorkspaceService(persistence: context.persistence, taskCodec: ObsidianTaskCodec(),
                                           attachmentStore: context.store)
        let link = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await service.addTask(
            selection: context.selection, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body, attachments: attachments, url: link?.isEmpty == false ? link : nil
        )
    }
}
