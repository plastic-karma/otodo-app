import Foundation
import OTodoCore
import PhotosUI
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Imports live in the editor until its one workspace transaction succeeds.
struct TaskAttachmentSection: View {
    let model: AppModel
    let selection: RepositorySelection
    @Binding var draft: TaskEditorDraft
    let configuration: StoreConfiguration
    @State private var choosesFiles = false
    @State private var photos: [PhotosPickerItem] = []
    @Binding var isImporting: Bool
    @State private var importError: String?
    @Binding var isEditorPresented: Bool

    private var links: [AttachmentLink] {
        let path = draft.preservedTask?.relativePath ?? configuration.tasksDirectory + "/draft.md"
        var seen: Set<String> = []
        return AttachmentLinks.references(body: draft.body, taskPath: path, storePrefix: configuration.obsidianLinkPrefix).filter {
            !draft.removingAttachmentPaths.contains($0.path) && seen.insert($0.path).inserted
        }
    }

    var body: some View {
        Section {
            ForEach(links, id: \.path) { link in
                AttachmentRow(model: model, selection: selection, path: link.path,
                              name: link.displayName, imported: nil) {
                    draft.removingAttachmentPaths.append(link.path)
                }
            }
            ForEach(draft.attachments, id: \.id) { attachment in
                AttachmentRow(model: model, selection: selection, path: attachment.path,
                              name: attachment.displayName, imported: attachment) {
                    draft.attachments.removeAll { $0.id == attachment.id }
                    Task { await model.discardAttachmentDrafts([attachment], selection: selection) }
                }
            }
            Button("Choose Files", systemImage: "folder") { choosesFiles = true }
                .accessibilityIdentifier("attachment-choose-files")
            PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .images,
                         preferredItemEncoding: .current) {
                Label("Choose Photos", systemImage: "photo")
            }
            .accessibilityIdentifier("attachment-choose-photos")
            if isImporting { ProgressView("Importing attachments…") }
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("attachment-import-error")
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-attachment-import") {
                Button("Import Sample File") {
                    importOperation {
                        if ProcessInfo.processInfo.arguments.contains("-ui-testing-slow-attachment-import") {
                            try await Task.sleep(for: .milliseconds(1500))
                        }
                        return [try await model.attachmentStore.stage(
                            data: Data("Attachment UI test\n".utf8), filename: "sample.txt", selection: selection
                        )]
                    }
                }.accessibilityIdentifier("attachment-import-sample")
            }
            #endif
        } header: {
            Text("Attachments")
        } footer: {
            Text("Up to 20 MiB per file. Removing a link keeps the file in your vault. Use explicit Attachments/ paths for manually added links.")
        }
        .disabled(isImporting)
        .fileImporter(isPresented: $choosesFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                importOperation {
                    var staged: [AttachmentDraft] = []
                    do {
                        for url in urls {
                            let accessed = url.startAccessingSecurityScopedResource()
                            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                            staged.append(try await model.attachmentStore.stage(sourceURL: url, selection: selection))
                        }
                        return staged
                    } catch {
                        await model.discardAttachmentDrafts(staged, selection: selection)
                        throw error
                    }
                }
            case let .failure(error): importError = error.localizedDescription
            }
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            importOperation {
                var staged: [AttachmentDraft] = []
                do {
                    for item in items {
                        guard let file = try await item.loadTransferable(type: AttachmentPhotoFile.self) else {
                            throw OTodoError.validation(field: "attachment", message: "The photo could not be imported")
                        }
                        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
                        staged.append(try await model.attachmentStore.stage(sourceURL: file.url, selection: selection))
                    }
                    return staged
                } catch {
                    await model.discardAttachmentDrafts(staged, selection: selection)
                    throw error
                }
            }
            photos = []
        }
    }

    private func importOperation(_ operation: @escaping @MainActor () async throws -> [AttachmentDraft]) {
        guard !isImporting else { return }
        isImporting = true
        importError = nil
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let staged = try await operation()
                if isEditorPresented { draft.attachments.append(contentsOf: staged) }
                else { await model.discardAttachmentDrafts(staged, selection: selection) }
            } catch { importError = error.localizedDescription }
        }
    }
}

/// File transfer avoids materializing unbounded Photos data in the extension/app heap.
private struct AttachmentPhotoFile: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let source = received.file
            let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 20 * 1024 * 1024 else {
                throw OTodoError.validation(field: "attachment", message: "Photos must be regular files up to 20 MiB")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(source.lastPathComponent)
            do { try FileManager.default.copyItem(at: source, to: target) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
            return AttachmentPhotoFile(url: target)
        }
    }
}

private struct AttachmentRow: View {
    let model: AppModel
    let selection: RepositorySelection
    let path: String
    let name: String
    let imported: AttachmentDraft?
    let remove: () -> Void
    @State private var file: AttachmentCachedFile?
    @State private var thumbnail: UIImage?
    @State private var previewURL: URL?
    @State private var failure: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit().frame(width: 44, height: 44)
                } else {
                    Image(systemName: "doc").frame(width: 44, height: 44).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text(name).lineLimit(2)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading { ProgressView() }
            }
            HStack {
                Button("Open") { load(preview: true) }
                    .accessibilityIdentifier("attachment-open.\(path)")
                if let file {
                    ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                Menu {
                    if imported == nil {
                        Button(file?.isPinned == true ? "Allow Cache Eviction" : "Keep Offline",
                               systemImage: "pin") { pin() }
                    }
                    Button("Remove Link", systemImage: "link.badge.plus", role: .destructive, action: remove)
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Attachment actions for \(name)") }
                .accessibilityIdentifier("attachment-actions.\(path)")
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .quickLookPreview($previewURL)
        .task(id: CacheRefreshKey(catalog: model.attachmentCatalog, revision: model.attachmentCacheRevision)) { await refreshCachedFile() }
    }

    private struct CacheRefreshKey: Equatable {
        let catalog: [AttachmentMetadata]
        let revision: UInt64
    }

    private var status: String {
        if imported != nil { return "Selected · saves with this todo" }
        if file?.isOlderVersion == true { return "Older cached version · update unavailable" }
        if file?.isPinned == true { return "Kept offline" }
        if file != nil { return "Available offline" }
        return model.attachmentMetadata(path: path, selection: selection) == nil
            ? "Missing file" : "Download to open"
    }

    private func refreshCachedFile() async {
        do {
            file = try await model.cachedAttachment(path: path, imported: imported, selection: selection)
            if let file { await makeThumbnail(file.url) }
        } catch { failure = error.localizedDescription }
    }

    private func load(preview: Bool) {
        isLoading = true
        failure = nil
        Task { @MainActor in
            defer { isLoading = false }
            do {
                file = try await model.openAttachment(path: path, imported: imported, selection: selection)
                if let file {
                    if preview { previewURL = file.url }
                    await makeThumbnail(file.url)
                }
            } catch { failure = error.localizedDescription }
        }
    }

    private func pin() {
        isLoading = true
        failure = nil
        Task { @MainActor in
            defer { isLoading = false }
            do {
                try await model.pinAttachment(path: path, pinned: file?.isPinned != true, selection: selection)
                await refreshCachedFile()
            } catch { failure = error.localizedDescription }
        }
    }

    private func makeThumbnail(_ url: URL) async {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 88, height: 88),
                                                  scale: 2, representationTypes: .thumbnail)
        if let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = result.uiImage
        }
    }
}
