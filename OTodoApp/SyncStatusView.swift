import SwiftUI

struct SyncStatusView: View {
    @Bindable private var model: AppModel
    @State private var isReviewingConflicts = false

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: primarySymbol)
                    .font(.caption)
                    .foregroundStyle(primaryColor)
                    .accessibilityHidden(true)

                Text(primaryText)
                    .font(.caption.weight(requiresAttention ? .semibold : .regular))
                    .foregroundStyle(requiresAttention ? .primary : .secondary)

                Spacer(minLength: 8)

                if !model.conflicts.isEmpty {
                    Button("Review") {
                        isReviewingConflicts = true
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Shows each affected task and the available resolution choices")
                    .accessibilityIdentifier("sync-review-conflicts")
                }

                if model.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Sync in progress")
                } else {
                    Button {
                        Task { @MainActor in
                            await model.refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.isOnline)
                    .accessibilityLabel(model.isOnline ? "Sync now" : "Sync unavailable while offline")
                    .accessibilityIdentifier("sync-refresh")
                }
            }

            if let detailText {
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-status")
        .sheet(isPresented: $isReviewingConflicts) {
            ConflictResolutionView(model: model)
        }
    }

    private var requiresAttention: Bool {
        !model.isOnline || !model.conflicts.isEmpty
    }

    private var detailText: String? {
        if !model.conflicts.isEmpty {
            return countText(
                model.conflicts.count,
                singular: "conflict needs attention",
                plural: "conflicts need attention"
            )
        }
        if model.pendingChangeCount > 0 {
            return countText(
                model.pendingChangeCount,
                singular: "change waiting to sync",
                plural: "changes waiting to sync"
            )
        }
        return model.statusMessage.flatMap { $0.isEmpty ? nil : $0 }
    }

    private var primaryText: String {
        if !model.isOnline {
            return "Offline — changes stay on this device"
        }
        if !model.conflicts.isEmpty {
            return "Sync needs attention"
        }
        if model.isBusy {
            return "Syncing"
        }
        if model.pendingChangeCount > 0 {
            return "Waiting to sync"
        }
        return "Up to date"
    }

    private var primarySymbol: String {
        if !model.isOnline {
            return "wifi.slash"
        }
        if !model.conflicts.isEmpty {
            return "exclamationmark.triangle"
        }
        if model.isBusy {
            return "arrow.triangle.2.circlepath"
        }
        if model.pendingChangeCount > 0 {
            return "clock.arrow.circlepath"
        }
        return "checkmark.circle"
    }

    private var primaryColor: Color {
        if !model.isOnline || !model.conflicts.isEmpty {
            return .orange
        }
        if model.isBusy || model.pendingChangeCount > 0 {
            return .blue
        }
        return .green
    }

    private func countText(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
