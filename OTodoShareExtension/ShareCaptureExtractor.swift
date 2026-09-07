import Foundation
import OTodoCore
import UIKit
import UniformTypeIdentifiers

@MainActor
enum ShareCaptureExtractor {
    struct Capture {
        let name: String
        let body: String
        let files: [URL]

        func cleanTemporaryFiles() {
            for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        }
    }

    static func extract(_ items: [NSExtensionItem]) async throws -> Capture {
        var captures: [TaskCapture] = []
        var files: [URL] = []
        var succeeded = false
        defer {
            if !succeeded {
                for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            }
        }
        for item in items {
            try Task.checkCancellation()
            var title = item.attributedTitle?.string
            var texts: [String] = []
            var urls: [URL] = []
            append(item.attributedContentText?.string, to: &texts)

            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    let url = try await loadURL(provider, identifier: UTType.fileURL.identifier)
                    files.append(url)
                    continue
                }
                // Prefer a file representation for binary data; URL and text providers keep
                // their established source-context semantics.
                if let identifier = provider.registeredTypeIdentifiers.first(where: {
                    guard let type = UTType($0) else { return false }
                    return type.conforms(to: .image) || (type.conforms(to: .data)
                        && !type.conforms(to: .text) && !type.conforms(to: .url)
                        && !type.conforms(to: .propertyList))
                }) {
                    files.append(try await loadFile(provider, identifier: identifier))
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                   let page = try await loadWebPage(provider) {
                    if !page.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if title != page.title { append(title, to: &texts) }
                        title = page.title
                    }
                    append(page.selection, to: &texts)
                    if !urls.contains(page.url) { urls.append(page.url) }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let url = try await loadURL(provider)
                    if url.isFileURL { files.append(url) }
                    else if !urls.contains(url) { urls.append(url) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    let identifier = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                        ? UTType.plainText.identifier : UTType.text.identifier
                    append(try await loadText(provider, identifier: identifier), to: &texts)
                }
            }

            guard title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || !texts.isEmpty || !urls.isEmpty else { continue }
            captures.append(try TaskCapture(
                text: texts.isEmpty ? nil : texts.joined(separator: "\n\n"),
                sourceTitle: title,
                sourceURL: urls.first
            ))
            for url in urls.dropFirst() {
                captures.append(try TaskCapture(sourceURL: url))
            }
        }

        guard !captures.isEmpty || !files.isEmpty else {
            throw CaptureError("No readable content was shared. Share text, links, files, or images with OTodo.")
        }
        try Task.checkCancellation()
        succeeded = true
        return Capture(name: captures.first?.name ?? files[0].lastPathComponent,
                       body: captures.map(\.body).joined(separator: "\n\n---\n\n"), files: files)
    }

    private static func loadFile(_ provider: NSItemProvider, identifier: String) async throws -> URL {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CaptureError("The source app did not provide a file.") }
                    // The provider may delete this URL as soon as this callback returns.
                    let copy = try copyFile(url, suggestedName: suggestedName)
                    continuation.resume(returning: copy)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated private static func copyFile(_ source: URL, suggestedName: String? = nil) throws -> URL {
        guard source.isFileURL else { throw CaptureError("Expected a local file.") }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 20 * 1024 * 1024 else {
            throw CaptureError("Attachments must be regular files up to 20 MiB.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var name = (suggestedName as NSString?)?.lastPathComponent ?? source.lastPathComponent
        if name.isEmpty || name == "." || name == ".." { name = source.lastPathComponent }
        if (name as NSString).pathExtension.isEmpty && !source.pathExtension.isEmpty { name += "." + source.pathExtension }
        let target = directory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            let copied = try target.resourceValues(forKeys: [.fileSizeKey])
            guard let copiedSize = copied.fileSize, copiedSize <= 20 * 1024 * 1024 else {
                throw CaptureError("Attachments must be at most 20 MiB.")
            }
            return target
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func append(_ text: String?, to texts: inout [String]) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !texts.contains(text) else { return }
        texts.append(text)
    }

    private struct WebPage: Sendable {
        let title: String
        let url: URL
        let selection: String?
    }

    private static func loadWebPage(_ provider: NSItemProvider) async throws -> WebPage? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: CaptureError("Could not read the source webpage: \(error.localizedDescription)"))
                    return
                }
                guard let values = (item as? [String: Any])?[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] else {
                    continuation.resume(returning: nil)
                    return
                }
                guard let address = values["url"] as? String,
                      let url = URL(string: address), url.scheme != nil else {
                    continuation.resume(throwing: CaptureError("Safari did not provide a readable source link."))
                    return
                }
                continuation.resume(returning: WebPage(
                    title: values["title"] as? String ?? "",
                    url: url,
                    selection: values["selection"] as? String
                ))
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider, identifier: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: CaptureError("Could not read shared text: \(error.localizedDescription)"))
                    return
                }
                let text: String?
                if let attributed = item as? NSAttributedString {
                    text = attributed.string
                } else if let string = item as? String {
                    text = string
                } else if let data = item as? Data {
                    text = String(data: data, encoding: .utf8)
                } else if let url = item as? URL, url.isFileURL {
                    do {
                        text = try String(contentsOf: url, encoding: .utf8)
                    } catch {
                        continuation.resume(throwing: CaptureError("Could not read shared text: \(error.localizedDescription)"))
                        return
                    }
                } else {
                    text = nil
                }
                guard let text else {
                    continuation.resume(throwing: CaptureError("The source app did not provide readable text. Try sharing plain text or a webpage URL."))
                    return
                }
                continuation.resume(returning: text)
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider, identifier: String = UTType.url.identifier) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: CaptureError("Could not read a shared link: \(error.localizedDescription)"))
                    return
                }
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let string = item as? String {
                    url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
                    url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    url = nil
                }
                guard let url, url.scheme != nil else {
                    continuation.resume(throwing: CaptureError("The source app did not provide a valid link. Try sharing the webpage again."))
                    return
                }
                do {
                    continuation.resume(returning: url.isFileURL ? try copyFile(url) : url)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private struct CaptureError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
