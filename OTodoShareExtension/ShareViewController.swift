import OTodoCore
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
    private(set) var attachments: [AttachmentDraft] = []
    private var attachmentContext: SharedTaskCapture.AttachmentContext?
    private(set) var isCancelled = false
    private var loadingTask: Task<Void, Never>?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var hasCapture = false
    private(set) var errorMessage: String?

    private let items: [NSExtensionItem]
    private let onSave: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void

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
        let task = Task { await loadContents() }
        loadingTask = task
        await task.value
        loadingTask = nil
        isLoading = false
    }

    private func loadContents() async {
        errorMessage = nil
        do {
            let capture = try await ShareCaptureExtractor.extract(items)
            defer { capture.cleanTemporaryFiles() }
            try Task.checkCancellation()
            if !capture.files.isEmpty {
                let context = try await SharedTaskCapture.attachmentContext()
                attachmentContext = context
                for file in capture.files {
                    attachments.append(try await context.store.stage(sourceURL: file, selection: context.selection))
                }
            }
            if isCancelled { await cleanup(); return }
            try Task.checkCancellation()
            name = capture.name
            body = capture.body
            hasCapture = true
        } catch is CancellationError {
            await cleanup()
            return
        } catch {
            await cleanup()
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        guard !isSaving, !isCancelled else { return }
        isCancelled = true
        let loading = loadingTask
        loading?.cancel()
        Task {
            // A provider callback can finish copying after cancellation. Join that work
            // before cleaning its drafts and completing the extension request.
            await loading?.value
            await cleanup()
            onCancel()
        }
    }

    func remove(_ attachment: AttachmentDraft) {
        attachments.removeAll { $0.id == attachment.id }
        if let context = attachmentContext {
            Task { try? await context.store.discard(drafts: [attachment], selection: context.selection, persistence: context.persistence) }
        }
    }

    private func cleanup() async {
        if let context = attachmentContext {
            try? await context.store.discard(drafts: attachments, selection: context.selection, persistence: context.persistence)
        }
        attachments = []
    }

    func save() async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        do {
            _ = try await SharedTaskCapture.save(name: name, body: body, attachments: attachments,
                                                 expectedSelection: attachmentContext?.selection)
            attachments = []
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
                        ProgressView(model.isCancelled ? "Canceling import…" : "Reading shared content…")
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
                    if !model.attachments.isEmpty {
                        Section("Attachments") {
                            ForEach(model.attachments, id: \.id) { attachment in
                                HStack {
                                    Label(attachment.displayName, systemImage: "doc")
                                    Spacer()
                                    Button("Remove", role: .destructive) { model.remove(attachment) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    Section {
                        TextEditor(text: $model.body)
                            .frame(minHeight: 180)
                            .accessibilityLabel("Markdown context")
                            .accessibilityIdentifier("share-capture-context")
                    } header: {
                        Text("Context")
                    } footer: {
                        Text("Saves to Inbox without a project or due date. Shared text and attachment links are kept as Markdown. Files are saved with the todo.")
                    }
                }
            }
            .disabled(model.isSaving)
            .navigationTitle("Add Todo")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: model.cancel)
                        .disabled(model.isSaving || model.isCancelled)
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

