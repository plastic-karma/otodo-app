import Foundation
import OTodoCore
import SwiftUI

struct RelativeDueDateField: View {
    private static let helpText =
        "Set from now using minutes, hours, days, weeks, months, or years."
    private static let invalidText =
        "Use a phrase such as “in 3 days” or “in 6 hours”."

    let accessibilityIdentifierPrefix: String
    let onPendingChange: (Bool) -> Void
    let onApply: (Date, RelativeDueDateExpression.Unit) -> Void

    @State private var text = ""
    @State private var parsedExpression: RelativeDueDateExpression?
    @State private var resolutionError: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("in 3 days", text: textBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(apply)
                    .focused($isFocused)
                    .accessibilityLabel("Relative due date")
                    .accessibilityIdentifier("\(accessibilityIdentifierPrefix)-date")

                Button("Apply") {
                    apply()
                }
                .buttonStyle(.bordered)
                .disabled(parsedExpression == nil)
                .accessibilityIdentifier("\(accessibilityIdentifierPrefix)-apply")
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Invalid relative due date. \(validationMessage)")
            } else {
                Text(Self.helpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                let wasPending = hasPendingInput
                text = newValue
                let isPending = !newValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                parsedExpression = isPending
                    ? (try? RelativeDueDateExpression(newValue))
                    : nil
                resolutionError = nil
                if isPending != wasPending {
                    onPendingChange(isPending)
                }
            }
        )
    }

    private var hasPendingInput: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var validationMessage: String? {
        if let resolutionError {
            return resolutionError
        }
        return hasPendingInput && parsedExpression == nil ? Self.invalidText : nil
    }

    private func apply() {
        guard let parsedExpression else { return }
        do {
            let resolved = try parsedExpression.resolve(calendar: TaskSchedule.calendar)
            let resolvedDate = TaskSchedule.date(from: resolved.date, time: resolved.time)
            isFocused = false
            text = ""
            self.parsedExpression = nil
            resolutionError = nil
            onPendingChange(false)
            onApply(resolvedDate, parsedExpression.unit)
        } catch {
            resolutionError = error.localizedDescription
        }
    }
}
