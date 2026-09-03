import SwiftUI

struct SyncStatusView: View {
    @Bindable private var model: AppModel
    @State private var isReviewingConflicts = false

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: primarySymbol)
                .font(.title3)
                .foregroundStyle(primaryColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryText)
                    .font(.subheadline.weight(.semibold))

                if !model.conflicts.isEmpty {
                    Text(countText(model.conflicts.count, singular: "conflict needs attention", plural: "conflicts need attention"))

                    Button("Review Conflicts") {
                        isReviewingConflicts = true
                    }
                    .accessibilityHint("Shows each affected task and the available resolution choices")
                    .accessibilityIdentifier("sync-review-conflicts")
                }
                if model.pendingChangeCount > 0 {
                    Text(countText(model.pendingChangeCount, singular: "change waiting to sync", plural: "changes waiting to sync"))
                }
                if let statusMessage = model.statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Sync in progress")
            } else {
                Button {
                    Task { @MainActor in
                        await model.refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!model.isOnline)
                .accessibilityLabel(model.isOnline ? "Sync now" : "Sync unavailable while offline")
                .accessibilityIdentifier("sync-refresh")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-status")
        .sheet(isPresented: $isReviewingConflicts) {
            ConflictResolutionView(model: model)
        }
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
