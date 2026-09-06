import Observation
import SwiftUI
import UIKit

@MainActor
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        isModalInPresentation = true

        let model = ShareCaptureModel(
            items: extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [],
            onSave: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSUserCancelledError
                ))
            }
        )
        let host = UIHostingController(rootView: ShareCaptureView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

@MainActor
@Observable
private final class ShareCaptureModel {
    var name = ""
    var body = ""
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var hasCapture = false
    private(set) var errorMessage: String?

    private let items: [NSExtensionItem]
    private let onSave: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    init(
        items: [NSExtensionItem],
        onSave: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.items = items
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var canSave: Bool {
        hasCapture && !isLoading && !isSaving
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load() async {
        guard !isLoading, !hasCapture else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let capture = try await ShareCaptureExtractor.extract(items)
            try Task.checkCancellation()
            name = capture.name
            body = capture.body
            hasCapture = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save() async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        do {
            _ = try await SharedTaskCapture.save(name: name, body: body)
            onSave()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

@MainActor
private struct ShareCaptureView: View {
    @Bindable var model: ShareCaptureModel

    var body: some View {
        NavigationStack {
            Form {
                if model.isLoading {
                    Section {
                        ProgressView("Reading shared content…")
                    }
                }
                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("share-capture-error")
                        if !model.hasCapture {
                            Button("Try Again") {
                                Task { await model.load() }
                            }
                            .disabled(model.isLoading)
                        }
                    }
                }
                if model.hasCapture {
                    Section("Todo") {
                        TextField("Todo name", text: $model.name)
                            .accessibilityIdentifier("share-capture-name")
                    }
                    Section {
                        TextEditor(text: $model.body)
                            .frame(minHeight: 180)
                            .accessibilityLabel("Markdown context")
                            .accessibilityIdentifier("share-capture-context")
                    } header: {
                        Text("Context")
                    } footer: {
                        Text("Saves to Inbox without a project or due date. Shared text and links are kept as Markdown.")
                    }
                }
            }
            .disabled(model.isSaving)
            .navigationTitle("Add Todo")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: model.onCancel)
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("share-capture-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await model.save() }
                    }
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("share-capture-save")
                }
            }
            .overlay {
                if model.isSaving {
                    ProgressView("Saving todo…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .task { await model.load() }
        }
        .tint(OTodoTheme.accent)
    }
}

