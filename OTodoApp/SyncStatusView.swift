import SwiftUI

struct SyncStatusView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model: AppModel
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
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        isShowingDetails.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: primarySymbol)
                            .font(.subheadline.weight(.semibold))
                        compactText
                            .font(.caption.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: isShowingDetails ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(OTodoTheme.secondaryText)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(primaryColor)
                .accessibilityLabel(primaryText)
                .accessibilityValue(detailText ?? Text(""))
                .accessibilityHint(
                    isShowingDetails
                        ? "Hides workspace details"
                        : model.isLocalOnly
                            ? "Shows local workspace details and relationship repair actions"
                            : "Shows sync details and workspace repair actions"
                )
                .accessibilityIdentifier("sync-details-toggle")

                if isShowingDetails || isEmphasized {
                    SyncRefreshButton(model: model)
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
                detailText
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
                    .foregroundStyle(OTodoTheme.coral)
                    .accessibilityIdentifier("attachment-refresh-status")
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private var compactText: Text {
        if requiresAttention { return Text("Needs attention") }
        if model.isLocalOnly { return primaryText }
        if model.pendingChangeCount > 0 {
            return model.isOnline
                ? Text("\(model.pendingChangeCount) pending")
                : Text("\(model.pendingChangeCount) saved · Offline")
        }
        if !model.isOnline { return Text("Offline") }
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
        requiresAttention || model.pendingChangeCount > 0 || model.isBusy || model.isSyncing
    }

    private var detailText: Text? {
        if let error = model.errorMessage, !error.isEmpty { return Text(error) }
        if !model.relationshipBlocks.isEmpty {
            return Text("\(model.relationshipBlocks.count) relationship changes withheld; saved locally")
        }
        if !model.hierarchy.issues.isEmpty {
            return Text("\(model.hierarchy.issues.count) workspace relationship issues")
        }
        if !model.conflicts.isEmpty {
            return model.conflicts.count == 1
                ? Text("\(model.conflicts.count) conflict needs attention")
                : Text("\(model.conflicts.count) conflicts need attention")
        }
        if model.isLocalOnly {
            return model.statusMessage.flatMap { $0.isEmpty ? nil : Text($0) }
                ?? Text("No GitHub connection")
        }
        if model.pendingChangeCount > 0 {
            return model.pendingChangeCount == 1
                ? Text("\(model.pendingChangeCount) change waiting to sync")
                : Text("\(model.pendingChangeCount) changes waiting to sync")
        }
        return model.statusMessage.flatMap { $0.isEmpty ? nil : Text($0) }
    }

    private var primaryText: Text {
        if model.errorMessage?.isEmpty == false { return Text("Sync needs attention") }
        if hasRelationshipIssues {
            return Text("Relationships need attention")
        }
        if !model.conflicts.isEmpty {
            return Text("Sync needs attention")
        }
        if !model.attachmentRefreshErrors.isEmpty {
            return Text("Attachment updates need attention")
        }
        if model.isBusy {
            return Text("Saving")
        }
        if model.isSyncing {
            return Text("Syncing")
        }
        if model.isLocalOnly {
            return Text("On this device")
        }
        if !model.isOnline {
            return Text("Saved on this device")
        }
        if model.pendingChangeCount > 0 {
            return Text("Waiting to sync")
        }
        return Text("Synced")
    }

    private var primarySymbol: String {
        if requiresAttention {
            return "exclamationmark.triangle"
        }
        if model.isBusy || model.isSyncing {
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
        if model.isBusy || model.isSyncing {
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

}

private struct SyncRefreshButton: View {
    let model: AppModel

    var body: some View {
        if model.isBusy || model.isSyncing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 44, height: 44)
                .accessibilityLabel(model.isBusy ? "Local save in progress" : "Sync in progress")
        } else {
            Button {
                Task { @MainActor in
                    await model.refresh()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
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
}
