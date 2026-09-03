import OTodoCore
import SwiftUI
import UIKit

struct AuthenticationView: View {
    @Bindable private var model: AppModel
    @Environment(\.openURL) private var openURL

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if let deviceCode = model.deviceCode {
                        authorizationCard(for: deviceCode)
                    } else {
                        startCard
                    }

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
                .frame(maxWidth: 560, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Sign in to GitHub")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "checklist")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Connect OTodo")
                .font(.title.bold())

            Text("Authorize this device to access your GitHub repositories. OTodo never asks for a personal access token or your GitHub password.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var startCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GitHub will show a one-time code, then ask you to approve OTodo in your browser.")
                .foregroundStyle(.secondary)

            if model.isBusy {
                ProgressView("Requesting a code…")
                    .accessibilityIdentifier("authentication.requestingCode")

                Button("Cancel", role: .cancel) {
                    Task {
                        await model.cancelAuthorization()
                    }
                }
                .accessibilityIdentifier("authentication.cancel")
            } else {
                Button {
                    Task {
                        await model.startAuthorization()
                    }
                } label: {
                    Label("Continue with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Requests a one-time code from GitHub")
                .accessibilityIdentifier("authentication.start")
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func authorizationCard(for deviceCode: OAuthDeviceCode) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isExpired = context.date >= deviceCode.expiresAt

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your one-time code")
                        .font(.headline)

                    Text(deviceCode.userCode)
                        .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                        .textSelection(.enabled)
                        .foregroundStyle(isExpired ? .secondary : .primary)
                        .accessibilityLabel("GitHub authorization code")
                        .accessibilityValue(deviceCode.userCode)
                        .accessibilityIdentifier("authentication.userCode")

                    Button {
                        UIPasteboard.general.string = deviceCode.userCode
                    } label: {
                        Label("Copy code", systemImage: "doc.on.doc")
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

                Button("Cancel authorization", role: .cancel) {
                    Task {
                        await model.cancelAuthorization()
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("authentication.cancel")
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
