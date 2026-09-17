import SwiftUI

struct SyncStatusView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable private var model: AppModel
    @State private var isReviewingConflicts = false
    @State private var isReviewingRelationships = false
    @State private var isShowingDetails = false

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isShowingDetails.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: primarySymbol)
                            .font(.system(size: 16))
                        Text(compactText)
                            .font(.caption.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: isShowingDetails ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OTodoTheme.secondaryText)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(primaryColor)
                .accessibilityLabel(primaryText)
                .accessibilityValue(detailText ?? "")
                .accessibilityHint(
                    isShowingDetails
                        ? "Hides workspace details"
                        : model.isLocalOnly
                            ? "Shows local workspace details and relationship repair actions"
                            : "Shows sync details and workspace repair actions"
                )
                .accessibilityIdentifier("sync-details-toggle")

                if isShowingDetails || isEmphasized {
                    refreshButton
                }
            }

            if isShowingDetails {
                Divider()
                    .padding(.horizontal, 4)

                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView {
                        statusDetails
                    }
                    .frame(maxHeight: 240)
                } else {
                    statusDetails
                }
            }
        }
        .padding(.horizontal, isShowingDetails || isEmphasized ? OTodoTheme.Spacing.medium : 0)
        .padding(.vertical, isShowingDetails || isEmphasized ? 4 : 0)
        .background(
            isShowingDetails || isEmphasized ? OTodoTheme.formCanvas : Color.clear,
            in: RoundedRectangle(cornerRadius: OTodoTheme.Radius.control)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-status")
        .sheet(isPresented: $isReviewingConflicts) {
            ConflictResolutionView(model: model)
        }
        .sheet(isPresented: $isReviewingRelationships) {
            TaskRelationshipReview(model: model)
        }
    }

    private var statusDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let detailText {
                Text(detailText)
                    .font(.footnote)
                    .foregroundStyle(OTodoTheme.secondaryText)
            }

            relationshipReviewButton

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
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("attachment-refresh-status")
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var refreshButton: some View {
        if model.isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 44, height: 44)
                .accessibilityLabel(model.isLocalOnly ? "Local save in progress" : "Sync in progress")
        } else {
            Button {
                Task { @MainActor in
                    await model.refresh()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!model.isLocalOnly && !model.isOnline)
            .accessibilityLabel(
                model.isLocalOnly
                    ? "Refresh local workspace"
                    : model.isOnline ? "Sync now" : "Sync unavailable while offline"
            )
            .accessibilityIdentifier("sync-refresh")
        }
    }

    private var compactText: String {
        if requiresAttention { return "Needs attention" }
        if model.isLocalOnly { return primaryText }
        if model.pendingChangeCount > 0 {
            return model.isOnline ? "\(model.pendingChangeCount) pending" : "\(model.pendingChangeCount) saved · Offline"
        }
        if !model.isOnline { return "Offline" }
        return primaryText
    }

    private var relationshipReviewButton: some View {
        Button {
            isReviewingRelationships = true
        } label: {
            Label(
                hasRelationshipIssues ? "Review hierarchy issues" : "Hierarchy",
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
            || model.errorMessage?.isEmpty == false
    }

    private var isEmphasized: Bool {
        requiresAttention || model.pendingChangeCount > 0 || model.isBusy
    }

    private var detailText: String? {
        if let error = model.errorMessage, !error.isEmpty { return error }
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
        if model.isLocalOnly {
            return model.statusMessage.flatMap { $0.isEmpty ? nil : $0 }
                ?? "No GitHub connection"
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
        if model.errorMessage?.isEmpty == false { return "Sync needs attention" }
        if hasRelationshipIssues {
            return "Relationships need attention"
        }
        if !model.conflicts.isEmpty {
            return "Sync needs attention"
        }
        if !model.attachmentRefreshErrors.isEmpty {
            return "Attachment updates need attention"
        }
        if model.isBusy {
            return model.isLocalOnly ? "Saving" : "Syncing"
        }
        if model.isLocalOnly {
            return "On this device"
        }
        if !model.isOnline {
            return "Saved on this device"
        }
        if model.pendingChangeCount > 0 {
            return "Waiting to sync"
        }
        return "Synced"
    }

    private var primarySymbol: String {
        if requiresAttention {
            return "exclamationmark.triangle"
        }
        if model.isBusy {
            return "arrow.triangle.2.circlepath"
        }
        if model.isLocalOnly {
            return "internaldrive"
        }
        if !model.isOnline {
            return "wifi.slash"
        }
        if model.pendingChangeCount > 0 {
            return "clock.arrow.circlepath"
        }
        return "checkmark.icloud"
    }

    private var primaryColor: Color {
        if requiresAttention {
            return OTodoTheme.warmForeground
        }
        if model.isBusy {
            return OTodoTheme.accent
        }
        if model.isLocalOnly {
            return OTodoTheme.secondaryText
        }
        if !model.isOnline {
            return .primary
        }
        if model.pendingChangeCount > 0 {
            return OTodoTheme.accent
        }
        return OTodoTheme.secondaryText
    }

    private func countText(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
