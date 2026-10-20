import OTodoCore
import XCTest
@testable import OTodo

@MainActor
final class AppModelErrorStateTests: XCTestCase {
    func testSyncAuthorizationFailurePreservesLocalValidationError() async throws {
        let model = try await makeWorkspace()
        let task = try XCTUnwrap(model.tasks.first)
        var draft = TaskEditorDraft(task: task)
        draft.name = ""

        await model.updateTask(id: task.id, draft: draft)
        let localError = try XCTUnwrap(model.errorMessage)
        XCTAssertNil(model.syncErrorMessage)

        // The offline fixture has no GitHub credentials. Refresh must report that
        // separately, without turning a rejected save into a successful callback.
        await model.refresh()
        let syncError = try XCTUnwrap(model.syncErrorMessage)
        XCTAssertEqual(model.errorMessage, localError)
        XCTAssertFalse(model.hasSyncedWorkspace)
        XCTAssertEqual(model.tasks.first { $0.id == task.id }, task)

        await model.refresh()
        await model.sceneDidBecomeActive()
        XCTAssertEqual(model.errorMessage, localError)
        XCTAssertEqual(model.syncErrorMessage, syncError)
        await model.signOut()
    }

    func testLocalSaveResultIsIndependentOfExistingSyncFailure() async throws {
        let model = try await makeWorkspace()
        await model.refresh()
        let syncError = try XCTUnwrap(model.syncErrorMessage)
        XCTAssertNil(model.errorMessage)
        let task = try XCTUnwrap(model.tasks.first)
        var draft = TaskEditorDraft(task: task)
        draft.name = ""

        await model.updateTask(id: task.id, draft: draft)
        XCTAssertNotNil(model.errorMessage, "A local validation failure must still fail the save callback")
        XCTAssertEqual(model.syncErrorMessage, syncError)

        draft.name = "Saved despite unavailable GitHub"
        await model.updateTask(id: task.id, draft: draft)
        XCTAssertNil(model.errorMessage, "The sync failure must not fail a durable local save")
        XCTAssertEqual(model.syncErrorMessage, syncError)
        XCTAssertEqual(model.tasks.first { $0.id == task.id }?.name, draft.name)

        let restored = try AppModel(infoDictionary: [:], launchArguments: ["-ui-testing"])
        await restored.start()
        XCTAssertEqual(restored.tasks.first { $0.id == task.id }?.name, draft.name)
        await model.signOut()
    }

    func testNewLocalSessionClearsSyncFailureButRefreshPreservesLocalError() async throws {
        let model = try await makeWorkspace()
        await model.refresh()
        XCTAssertNotNil(model.syncErrorMessage)

        await model.signOut()
        XCTAssertNil(model.syncErrorMessage)
        XCTAssertFalse(model.hasSyncedWorkspace)

        await model.useLocalStorage()
        XCTAssertTrue(model.isLocalOnly)
        XCTAssertNil(model.syncErrorMessage)
        let configuration = try XCTUnwrap(model.configuration)
        await model.createTask(draft: TaskEditorDraft(configuration: configuration))
        let localError = try XCTUnwrap(model.errorMessage)

        await model.refresh()
        XCTAssertEqual(model.errorMessage, localError)
        XCTAssertNil(model.syncErrorMessage)
        await model.signOut()
    }

    private func makeWorkspace() async throws -> AppModel {
        let model = try AppModel(
            infoDictionary: [:],
            launchArguments: ["-ui-testing", "-ui-testing-reset-workspace"]
        )
        await model.start()
        XCTAssertEqual(model.rootState, .workspace)
        XCTAssertNil(model.errorMessage)
        return model
    }
}
