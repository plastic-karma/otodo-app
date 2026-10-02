import OTodoCore
import SwiftUI
import UIKit

struct AuthenticationView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OTodoCanvas()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header

                        if let deviceCode = model.deviceCode {
                            GitHubAuthorizationCard(model: model, deviceCode: deviceCode)
                        } else {
                            AuthenticationStartCard(model: model)
                        }

                        AuthenticationStatus(model: model)
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 30)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        return layout {
            Image(systemName: "checkmark")
                .font(.title.bold())
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(OTodoTheme.heroGradient, in: RoundedRectangle(cornerRadius: 20))
                .shadow(color: OTodoTheme.accent.opacity(0.25), radius: 12, y: 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Meet OTodo")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)

                Text("A calm place for the work that matters.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}

private struct AuthenticationStatus: View {
    let model: AppModel

    var body: some View {
        if let errorMessage = model.errorMessage {
            Label {
                Text(errorMessage)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
            .accessibilityIdentifier("authentication.error")
        }

        if model.isBusy, let statusMessage = model.statusMessage {
            ProgressView(statusMessage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("authentication.progress")
        }
    }
}

private struct AuthenticationStartCard: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose where OTodo keeps this workspace.")
                .font(.headline)

            if model.isBusy {
                ProgressView {
                    if let statusMessage = model.statusMessage {
                        Text(statusMessage)
                    } else {
                        Text("Working…")
                    }
                }
                .accessibilityIdentifier("authentication.requestingCode")

                if model.isAuthorizingGitHub {
                    Button(role: .cancel) {
                        Task {
                            await model.cancelAuthorization()
                        }
                    } label: {
                        Text("Cancel")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("authentication.cancel")
                }
            } else {
                Text("Local storage needs no account or network connection. Todos stay inside OTodo on this device.")
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await model.useLocalStorage()
                    }
                } label: {
                    Label("Use This Device", systemImage: "internaldrive")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(OTodoTheme.filledAccent)
                .controlSize(.large)
                .accessibilityHint("Creates or opens a workspace stored only on this device")
                .accessibilityIdentifier("authentication.local")

                Divider()

                if model.gitHubClientID != nil {
                    Text("Or connect a GitHub repository to sync its todo store.")
                        .foregroundStyle(.secondary)

                    Button {
                        Task {
                            await model.startAuthorization()
                        }
                    } label: {
                        Label("Continue with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityHint("Requests a one-time code from GitHub")
                    .accessibilityIdentifier("authentication.start")
                } else {
                    Label("GitHub sign-in is not configured in this build.", systemImage: "key.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("authentication.githubUnavailable")
                }
            }
        }
        .padding(20)
        .background(
            OTodoTheme.raisedCard,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.045))
        }
        .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
    }

}

private struct GitHubAuthorizationCard: View {
    let model: AppModel
    let deviceCode: OAuthDeviceCode
    @Environment(\.openURL) private var openURL

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isExpired = context.date >= deviceCode.expiresAt

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your one-time code")
                        .font(.headline)

                    Text(deviceCode.userCode)
                        .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .foregroundStyle(isExpired ? .secondary : .primary)
                        .accessibilityLabel("GitHub authorization code")
                        .accessibilityValue(deviceCode.userCode)
                        .accessibilityIdentifier("authentication.userCode")

                    Button {
                        UIPasteboard.general.string = deviceCode.userCode
                    } label: {
                        Label("Copy code", systemImage: "doc.on.doc")
                            .frame(minHeight: 44)
                    }
                    .disabled(isExpired)
                    .accessibilityHint("Copies the authorization code to the clipboard")
                    .accessibilityIdentifier("authentication.copyCode")
                }

                expirationView(for: deviceCode, now: context.date)

                Text("Open GitHub, enter the code, and approve access. Return here afterward; sign-in will finish automatically.")
                    .foregroundStyle(.secondary)

                Button {
                    openURL(deviceCode.verificationURI)
                } label: {
                    Label("Open GitHub to authorize", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(OTodoTheme.filledAccent)
                .controlSize(.large)
                .disabled(isExpired)
                .accessibilityHint("Opens GitHub’s device authorization page")
                .accessibilityIdentifier("authentication.openGitHub")

                if isExpired || (!model.isBusy && model.errorMessage != nil) {
                    Button {
                        Task {
                            await model.cancelAuthorization()
                            await model.startAuthorization()
                        }
                    } label: {
                        Label("Request a new code", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("authentication.restart")
                }

                Button(role: .cancel) {
                    Task {
                        await model.cancelAuthorization()
                    }
                } label: {
                    Text("Cancel authorization")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("authentication.cancel")
            }
            .padding(20)
            .background(
                OTodoTheme.raisedCard,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.045))
            }
            .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
        }
    }

    @ViewBuilder
    private func expirationView(for deviceCode: OAuthDeviceCode, now: Date) -> some View {
        if now >= deviceCode.expiresAt {
            Label("This code has expired", systemImage: "clock.badge.exclamationmark")
                .font(.headline)
                .foregroundStyle(.red)
                .accessibilityIdentifier("authentication.expiration")
        } else {
            LabeledContent {
                Text(deviceCode.expiresAt, style: .relative)
                    .monospacedDigit()
            } label: {
                Label("Code expires", systemImage: "clock")
            }
            .accessibilityLabel("Authorization code expiration")
            .accessibilityValue(Text(deviceCode.expiresAt, style: .relative))
            .accessibilityIdentifier("authentication.expiration")
        }
    }
}
