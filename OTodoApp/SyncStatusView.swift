import SwiftUI

struct SyncStatusView: View {
    @Bindable private var model: AppModel
    @State private var isReviewingConflicts = false
    @State private var isReviewingRelationships = false

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: primarySymbol)
                            .foregroundStyle(primaryColor)
                            .accessibilityHidden(true)
                        Text(primaryText)
                            .foregroundStyle(requiresAttention ? .primary : .secondary)
                    }
                    .font(.caption.weight(.medium))

                    if let detailText {
                        Text(detailText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !hasRelationshipIssues {
                    relationshipReviewButton
                        .labelStyle(.iconOnly)
                }

                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Sync in progress")
                } else {
                    Button {
                        Task { @MainActor in
                            await model.refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.isOnline)
                    .accessibilityLabel(model.isOnline ? "Sync now" : "Sync unavailable while offline")
                    .accessibilityIdentifier("sync-refresh")
                }
            }

            if hasRelationshipIssues {
                relationshipReviewButton
            }
            if !model.conflicts.isEmpty {
                Button {
                    isReviewingConflicts = true
                } label: {
                    Label("Review conflicts", systemImage: "exclamationmark.bubble")
                        .font(.caption.weight(.medium))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Shows each affected task and the available resolution choices")
                .accessibilityIdentifier("sync-review-conflicts")
            }
            if !model.attachmentRefreshErrors.isEmpty {
                Text("\(model.attachmentRefreshErrors.count) offline attachment updates failed. Older cached files remain available.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("attachment-refresh-status")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(OTodoTheme.formCanvas, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-status")
        .sheet(isPresented: $isReviewingConflicts) {
            ConflictResolutionView(model: model)
        }
        .sheet(isPresented: $isReviewingRelationships) {
            TaskRelationshipReview(model: model)
        }
    }

    private var relationshipReviewButton: some View {
        Button {
            isReviewingRelationships = true
        } label: {
            Label(
                hasRelationshipIssues ? "Review relationship issues" : "Relationships",
                systemImage: hasRelationshipIssues ? "exclamationmark.triangle" : "arrow.turn.down.right"
            )
            .font(.caption.weight(.medium))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("sync-review-relationships")
    }

    private var hasRelationshipIssues: Bool {
        !model.hierarchy.issues.isEmpty || !model.relationshipBlocks.isEmpty
    }

    private var requiresAttention: Bool {
        !model.conflicts.isEmpty || hasRelationshipIssues || !model.attachmentRefreshErrors.isEmpty
    }

    private var detailText: String? {
        if !model.relationshipBlocks.isEmpty {
            return "\(model.relationshipBlocks.count) relationship changes withheld; saved locally"
        }
        if !model.hierarchy.issues.isEmpty {
            return "\(model.hierarchy.issues.count) workspace relationship issues"
        }
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
        if hasRelationshipIssues {
            return "Relationships need attention"
        }
        if !model.conflicts.isEmpty {
            return "Sync needs attention"
        }
        if !model.isOnline {
            return "Saved on this device"
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
        if hasRelationshipIssues { return "exclamationmark.triangle" }
        if !model.conflicts.isEmpty {
            return "exclamationmark.triangle"
        }
        if !model.isOnline {
            return "wifi.slash"
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
        if requiresAttention {
            return .orange
        }
        if !model.isOnline {
            return .secondary
        }
        if model.isBusy || model.pendingChangeCount > 0 {
            return OTodoTheme.accent
        }
        return OTodoTheme.mint
    }

    private func countText(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
