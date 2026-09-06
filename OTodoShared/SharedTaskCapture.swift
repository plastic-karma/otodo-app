import Foundation
import OTodoCore

/// Capture returns only after the normal Markdown workspace/outbox transaction succeeds.
enum SharedTaskCapture {
    static func save(name: String, body: String) async throws -> TodoTask {
        let directory = try SharedWorkspaceStorage.directoryURL()
        let selectionStore = RepositorySelectionStore(directoryURL: directory)
        guard let selection = try await selectionStore.load() else {
            throw OTodoError.validation(
                field: "workspace",
                message: "Open OTodo and connect a workspace before capturing todos."
            )
        }
        let store = FileWorkspaceStore(
            rootURL: directory.appendingPathComponent("workspaces", isDirectory: true)
        )
        let service = TaskWorkspaceService(persistence: store, taskCodec: ObsidianTaskCodec())
        return try await service.addTask(
            selection: selection,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body
        )
    }
}
