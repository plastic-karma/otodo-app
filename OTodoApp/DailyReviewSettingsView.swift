import OTodoCore
import SwiftUI

struct DailyReviewRequest: Identifiable {
    let id = UUID()
    let kind: DailyReviewKind
    let selection: WorkspaceSelection
    let date = Date()
}

struct DailyReviewPrompt: View {
    let model: AppModel
    let date: Date
    var onPresentationChange: (Bool) -> Void = { _ in }
    @State private var store = DailyReviewStore.shared
    @State private var request: DailyReviewRequest?

    var body: some View {
        Group {
            if let selection = model.workspaceSelection, model.configuration != nil {
                let workspace = DailyReviewContext.workspaceKey(selection)
                let due = DailyReviewKind.allCases.filter {
                    store.preference($0, workspace: workspace).isDue(kind: $0, at: date)
                }
                if !due.isEmpty {
                    Section("A moment for you") {
                        ForEach(due) { kind in
                            Button {
                                onPresentationChange(true)
                                request = DailyReviewRequest(kind: kind, selection: selection)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: kind.symbol)
                                        .font(.title2)
                                        .foregroundStyle(OTodoTheme.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(kind.title).font(.headline)
                                        Text(kind.invitation).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("daily-review-prompt-\(kind.rawValue)")
                        }
                    }
                }
            }
        }
        .sheet(item: $request, onDismiss: { onPresentationChange(false) }) { request in
            DailyReviewView(model: model, request: request)
        }
    }
}

struct DailyReviewSettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var store = DailyReviewStore.shared
    @State private var request: DailyReviewRequest?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("A little intention. A little reflection.", systemImage: "sparkles")
                        .font(.headline)
                    Text("Two optional moments to meet your day. Reviews appear here in OTodo, never as notifications or interruptions. Your choices stay on this device, separately for each workspace.")
                        .foregroundStyle(.secondary)
                }
                if let selection = model.workspaceSelection {
                    let workspace = DailyReviewContext.workspaceKey(selection)
                    ForEach(DailyReviewKind.allCases) { kind in
                        settings(kind, workspace: workspace, selection: selection)
                    }
                } else {
                    ContentUnavailableView("Choose a workspace", systemImage: "folder", description: Text("Daily reviews belong to your current todo workspace."))
                }
                if let message = store.errorMessage {
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(OTodoTheme.formCanvas)
            .navigationTitle("Daily review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $request) { request in
                DailyReviewView(model: model, request: request)
            }
        }
        .tint(OTodoTheme.accent)
        .accessibilityIdentifier("daily-review-settings")
    }

    private func settings(_ kind: DailyReviewKind, workspace: String, selection: WorkspaceSelection) -> some View {
        let preference = store.preference(kind, workspace: workspace)
        return Section {
            Toggle(isOn: Binding(
                get: { store.preference(kind, workspace: workspace).isEnabled },
                set: { enabled in
                    var updated = store.preference(kind, workspace: workspace)
                    updated.isEnabled = enabled
                    store.setPreference(updated, kind: kind, workspace: workspace)
                }
            )) { Label(kind.title, systemImage: kind.symbol) }
            .accessibilityIdentifier("daily-review-enabled-\(kind.rawValue)")
            if preference.isEnabled {
                DatePicker("Offer review from", selection: timeBinding(kind, workspace: workspace), in: timeRange(kind), displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("daily-review-time-\(kind.rawValue)")
            }
            Button {
                request = DailyReviewRequest(kind: kind, selection: selection)
            } label: {
                Label("Open \(kind.title.lowercased())", systemImage: "play.circle")
            }
            .disabled(model.isBusy || model.configuration == nil)
            .accessibilityIdentifier("daily-review-open-\(kind.rawValue)")
        } footer: {
            Text(kind == .morning
                ? "Available from your chosen time until 2 PM (earliest 4 AM). Start fresh, or resume a review you left open. You can replay any time, even with review offers off."
                : "Available from your chosen time until midnight (earliest 2 PM). Finish only when you acknowledge the last card; closing early keeps your place. You can replay any time.")
        }
    }

    private func date(for minute: Int) -> Date {
        Calendar.autoupdatingCurrent.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
    }

    private func timeRange(_ kind: DailyReviewKind) -> ClosedRange<Date> {
        date(for: kind.minuteWindow.lowerBound)...date(for: kind.minuteWindow.upperBound - 1)
    }

    private func timeBinding(_ kind: DailyReviewKind, workspace: String) -> Binding<Date> {
        Binding(
            get: { date(for: store.preference(kind, workspace: workspace).minuteOfDay) },
            set: { selected in
                var preference = store.preference(kind, workspace: workspace)
                let calendar = Calendar.autoupdatingCurrent
                let minute = calendar.component(.hour, from: selected) * 60 + calendar.component(.minute, from: selected)
                preference.minuteOfDay = max(kind.minuteWindow.lowerBound, min(minute, kind.minuteWindow.upperBound - 1))
                store.setPreference(preference, kind: kind, workspace: workspace)
            }
        )
    }
}
