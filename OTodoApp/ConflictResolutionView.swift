import OTodoCore
import SwiftUI

struct ConflictResolutionView: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable private var model: AppModel
    @State private var confirmation: ResolutionConfirmation?
    @State private var resolvingPath: String?

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Both this device and GitHub changed each task below. Choose which complete version to keep for every task.")
                } footer: {
                    Text("Review the affected path before choosing. OTodo cannot undo a resolution.")
                }

                if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
                    Section("Could Not Resolve Conflict") {
                        Label {
                            Text(errorMessage)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                        .accessibilityLabel("Conflict resolution error. \(errorMessage)")
                        .accessibilityIdentifier("conflict-resolution-error")
                    }
                }

                ForEach(model.conflicts, id: \.path) { conflict in
                    conflictSection(conflict)
                }
            }
            .accessibilityIdentifier("conflict-resolution-list")
            .navigationTitle("Review Conflicts")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isResolving)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .disabled(isResolving)
                    .accessibilityIdentifier("conflict-resolution-done")
                }
            }
            .overlay {
                if let resolvingPath {
                    ProgressView("Resolving \(resolvingPath)")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("conflict-resolution-progress")
                }
            }
            .confirmationDialog(
                confirmation?.title ?? "Resolve conflict?",
                isPresented: confirmationIsPresented,
                titleVisibility: .visible,
                presenting: confirmation
            ) { confirmation in
                Button(confirmation.actionTitle, role: .destructive) {
                    resolve(confirmation)
                }
                .disabled(isResolving)
                .accessibilityIdentifier(confirmation.confirmationAccessibilityIdentifier)

                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
            .onChange(of: model.conflicts.isEmpty) { _, conflictsAreEmpty in
                if conflictsAreEmpty {
                    dismiss()
                }
            }
        }
        .accessibilityIdentifier("conflict-resolution-sheet")
    }

    @ViewBuilder
    private func conflictSection(_ conflict: SyncConflict) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Affected task path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: conflict.path)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .accessibilityLabel("Affected task path, \(conflict.path)")
                    .accessibilityIdentifier("conflict-path.\(conflict.path)")
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                Text("Keep My Version")
                    .font(.headline)
                Text("Keeps this device’s task and queues it to replace the GitHub version during sync.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Keep My Version") {
                    confirmation = ResolutionConfirmation(
                        path: conflict.path,
                        resolution: .keepLocal
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isResolving)
                .accessibilityHint("Asks for confirmation before keeping this device’s version")
                .accessibilityIdentifier("conflict-keep-my-version.\(conflict.path)")
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                Text("Use GitHub Version")
                    .font(.headline)
                Text("Discards this device’s pending changes and replaces the task with GitHub’s version. If GitHub deleted the task, it will be removed here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Use GitHub Version") {
                    confirmation = ResolutionConfirmation(
                        path: conflict.path,
                        resolution: .useRemote
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isResolving)
                .accessibilityHint("Asks for confirmation before discarding this device’s version")
                .accessibilityIdentifier("conflict-use-github-version.\(conflict.path)")
            }
            .padding(.vertical, 2)
        }
    }

    private var isResolving: Bool {
        resolvingPath != nil || model.isBusy
    }

    private var confirmationIsPresented: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { isPresented in
                if !isPresented {
                    confirmation = nil
                }
            }
        )
    }

    private func resolve(_ confirmation: ResolutionConfirmation) {
        resolvingPath = confirmation.path
        self.confirmation = nil

        Task { @MainActor in
            await model.resolveConflict(
                path: confirmation.path,
                resolution: confirmation.resolution
            )
            resolvingPath = nil
            if model.conflicts.isEmpty {
                dismiss()
            }
        }
    }
}

private struct ResolutionConfirmation {
    let path: String
    let resolution: WorkspaceConflictResolution

    var title: String {
        switch resolution {
        case .keepLocal:
            return "Keep your version?"
        case .useRemote:
            return "Use the GitHub version?"
        }
    }

    var actionTitle: String {
        switch resolution {
        case .keepLocal:
            return "Keep My Version"
        case .useRemote:
            return "Use GitHub Version"
        }
    }

    var message: String {
        switch resolution {
        case .keepLocal:
            return "For \(path), your version will be queued to replace GitHub’s current version during sync."
        case .useRemote:
            return "For \(path), your pending changes will be discarded and GitHub’s current version will be used. If GitHub deleted the task, it will be removed from this device."
        }
    }

    var confirmationAccessibilityIdentifier: String {
        switch resolution {
        case .keepLocal:
            return "conflict-confirm-keep-my-version.\(path)"
        case .useRemote:
            return "conflict-confirm-use-github-version.\(path)"
        }
    }
}
