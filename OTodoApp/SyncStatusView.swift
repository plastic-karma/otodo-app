import SwiftUI

struct SyncStatusView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                    withAnimation(.snappy(duration: 0.2)) {
                        isShowingDetails.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: primarySymbol)
                            .font(.system(size: 16))
                        compactText
                            .font(.caption.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: isShowingDetails ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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

                SyncRefreshButton(model: model)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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

    private var statusDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let detailText {
                detailText
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("attachment-refresh-status")
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private var compactText: Text {
        if requiresAttention { return Text("Needs attention") }
        if model.isLocalOnly { return primaryText }
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
    }

    private var detailText: Text? {
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
            return model.isLocalOnly ? Text("Saving") : Text("Syncing")
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
        return Text("Up to date")
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
        return "checkmark.circle"
    }

    private var primaryColor: Color {
        if requiresAttention {
            return .orange
        }
        if model.isBusy {
            return OTodoTheme.accent
        }
        if model.isLocalOnly {
            return OTodoTheme.mint
        }
        if !model.isOnline {
            return .primary
        }
        if model.pendingChangeCount > 0 {
            return OTodoTheme.accent
        }
        return OTodoTheme.mint
    }

}

private struct SyncRefreshButton: View {
    let model: AppModel

    var body: some View {
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
}
