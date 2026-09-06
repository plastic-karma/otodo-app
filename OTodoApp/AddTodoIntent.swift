import AppIntents
import Foundation
import OTodoCore

struct AddTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Todo"
    static let description = IntentDescription(
        "Save text and an optional source link to your OTodo Inbox. Connect a workspace in OTodo first; captures also work offline."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Todo", description: "The todo text. Its first nonempty line becomes the name, and the full text is kept as context.", requestValueDialog: "What would you like to add to Inbox?")
    var text: String

    @Parameter(title: "Source URL", description: "An optional link to keep with the todo.")
    var sourceURL: URL?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text)") {
            \.$sourceURL
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let capture = try TaskCapture(text: text, sourceURL: sourceURL)
        let task = try await SharedTaskCapture.save(name: capture.name, body: capture.body)
        return .result(dialog: "Added “\(task.name)” to Inbox.")
    }
}

struct OTodoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTodoIntent(),
            phrases: [
                "Add a todo in \(.applicationName)",
                "Add a task in \(.applicationName)",
                "Capture a todo with \(.applicationName)",
            ],
            shortTitle: "Add Todo",
            systemImageName: "plus.circle"
        )
    }
}
