import Foundation

public struct AttachmentLink: Sendable, Equatable {
    public let path: String
    public let displayName: String
    public let isImage: Bool
}

/// Associations live exclusively in the Markdown body; no frontmatter keys are reserved.
public enum AttachmentLinks {
    public static let directory = "Attachments"
    public static let maximumBytes = 20 * 1_024 * 1_024
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic", "heif", "tiff", "tif", "avif"]

    public static func enabled(configuration: StoreConfiguration) -> Bool {
        ![configuration.tasksDirectory, configuration.projectsDirectory].contains {
            $0 == directory || $0.hasPrefix(directory + "/") || directory.hasPrefix($0 + "/")
        }
    }

    public static func validate(path: String) throws {
        try DomainValidation.validateRelativePath(path, field: "attachment.path")
        guard path.hasPrefix(directory + "/") else {
            throw OTodoError.validation(field: "attachment.path", message: "Use an explicit path inside Attachments/")
        }
    }

    public static func sanitizeFilename(_ name: String) -> String {
        var sanitized = String(name.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || "/\\:*?\"<>|".unicodeScalars.contains($0) ? "_" : String($0)
        }.joined()).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if sanitized.utf8.count > 200 {
            var bounded = ""
            for scalar in sanitized.unicodeScalars {
                guard bounded.utf8.count + scalar.utf8.count <= 200 else { break }
                bounded.unicodeScalars.append(scalar)
            }
            sanitized = bounded
        }
        return sanitized.isEmpty ? "attachment" : sanitized
    }

    public static func references(body: String, taskPath: String, storePrefix: String = "") -> [AttachmentLink] {
        var seen = Set<String>()
        return occurrences(body: body, taskPath: taskPath, storePrefix: storePrefix).compactMap { occurrence in
            seen.insert(occurrence.link.path).inserted ? occurrence.link : nil
        }
    }

    public static func unlink(body: String, taskPath: String, path: String, storePrefix: String = "") -> String {
        let result = NSMutableString(string: body)
        for occurrence in occurrences(body: body, taskPath: taskPath, storePrefix: storePrefix).reversed() where occurrence.link.path == path {
            result.replaceCharacters(in: occurrence.range, with: "")
        }
        return result as String
    }

    public static func append(body: String, taskPath: String, path: String, displayName: String) throws -> String {
        try validate(path: path)
        if references(body: body, taskPath: taskPath).contains(where: { $0.path == path }) { return body }
        let prefix = body.isEmpty ? "" : (body.hasSuffix("\n") ? "\n" : "\n\n")
        return body + prefix + "- " + markdown(taskPath: taskPath, path: path, displayName: displayName) + "\n"
    }

    public static func rebase(body: String, from oldTaskPath: String, to newTaskPath: String, storePrefix: String = "") -> String {
        let result = NSMutableString(string: body)
        for occurrence in occurrences(body: body, taskPath: oldTaskPath, storePrefix: storePrefix).reversed() {
            // Explicit wiki paths are independent of the task directory. Keep their aliases and fragments verbatim.
            if let range = occurrence.destinationRange {
                result.replaceCharacters(in: range, with: relativeDestination(taskPath: newTaskPath, path: occurrence.link.path))
            }
        }
        return result as String
    }

    public static func markdown(taskPath: String, path: String, displayName: String, image: Bool? = nil) -> String {
        let encoded = relativeDestination(taskPath: taskPath, path: path)
        let label = displayName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let isImage = image ?? imageExtensions.contains((path as NSString).pathExtension.lowercased())
        return "\(isImage ? "!" : "")[\(label)](\(encoded))"
    }

    private static func relativeDestination(taskPath: String, path: String) -> String {
        let parents = taskPath.split(separator: "/").dropLast().map(String.init)
        let target = path.split(separator: "/").map(String.init)
        var common = 0
        while common < parents.count && common < target.count && parents[common] == target[common] { common += 1 }
        let relative = (Array(repeating: "..", count: parents.count - common) + target.dropFirst(common)).joined(separator: "/")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        return relative.addingPercentEncoding(withAllowedCharacters: allowed) ?? relative
    }

    private struct Occurrence { let range: NSRange; let destinationRange: NSRange?; let link: AttachmentLink }
    private static func occurrences(body: String, taskPath: String, storePrefix: String) -> [Occurrence] {
        let text = body as NSString
        let bytes = Array(body.utf16)
        var results: [Occurrence] = []
        var fence: (marker: UInt16, length: Int)?
        var codeUntil = 0
        var offset = 0
        func escaped(_ index: Int) -> Bool {
            var current = index, slashes = 0
            while current > 0 && bytes[current - 1] == 92 { current -= 1; slashes += 1 }
            return slashes % 2 == 1
        }
        func substring(_ start: Int, _ end: Int) -> String { text.substring(with: NSRange(location: start, length: end - start)) }
        while offset < bytes.count {
            var lineEnd = offset
            while lineEnd < bytes.count && bytes[lineEnd] != 10 { lineEnd += 1 }
            let nextLine = lineEnd < bytes.count ? lineEnd + 1 : lineEnd
            var trimmed = offset
            while trimmed < lineEnd && bytes[trimmed] == 32 { trimmed += 1 }
            let indent = trimmed - offset
            var runEnd = trimmed
            if trimmed < lineEnd { while runEnd < lineEnd && bytes[runEnd] == bytes[trimmed] { runEnd += 1 } }
            let run = runEnd - trimmed
            if indent <= 3 && run >= 3 && (bytes[trimmed] == 96 || bytes[trimmed] == 126) {
                if let opened = fence {
                    if bytes[trimmed] == opened.marker && run >= opened.length && substring(runEnd, lineEnd).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fence = nil }
                } else { fence = (bytes[trimmed], run) }
                offset = nextLine; continue
            }
            if fence != nil || indent >= 4 || bytes[offset] == 9 { offset = nextLine; continue }
            var index = offset
            while index < lineEnd {
                if index < codeUntil { index = min(codeUntil, lineEnd); continue }
                if bytes[index] == 96 && !escaped(index) {
                    var ticksEnd = index
                    while ticksEnd < bytes.count && bytes[ticksEnd] == 96 { ticksEnd += 1 }
                    let ticks = ticksEnd - index
                    var candidate = ticksEnd
                    while candidate < bytes.count {
                        guard bytes[candidate] == 96 else { candidate += 1; continue }
                        var end = candidate
                        while end < bytes.count && bytes[end] == 96 { end += 1 }
                        if end - candidate == ticks { codeUntil = end; break }
                        candidate = end
                    }
                    if index < codeUntil { continue }
                }
                let start = index
                let bracket = bytes[index] == 33 && index + 1 < lineEnd && bytes[index + 1] == 91 ? index + 1 : index
                guard bytes[bracket] == 91 && !escaped(start) else { index += 1; continue }
                if bracket + 1 < lineEnd && bytes[bracket + 1] == 91 {
                    var end = bracket + 2
                    while end + 1 < lineEnd && !(bytes[end] == 93 && bytes[end + 1] == 93) { end += 1 }
                    if end + 1 < lineEnd {
                        let parts = substring(bracket + 2, end).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                        if let path = resolve(target: String(parts[0]), taskPath: taskPath, wiki: true, storePrefix: storePrefix) {
                            let label = parts.count > 1 ? String(parts[1]) : (path as NSString).lastPathComponent
                            results.append(Occurrence(range: NSRange(location: start, length: end + 2 - start), destinationRange: nil, link: AttachmentLink(path: path, displayName: label, isImage: bytes[start] == 33)))
                        }
                        index = end + 2; continue
                    }
                } else {
                    var close = bracket + 1, depth = 1
                    while close < lineEnd {
                        if bytes[close] == 92 { close += 2; continue }
                        if bytes[close] == 91 { depth += 1 }
                        if bytes[close] == 93 { depth -= 1; if depth == 0 { break } }
                        close += 1
                    }
                    if depth == 0 && close + 1 < lineEnd && bytes[close + 1] == 40 {
                        var end = close + 2
                        depth = 1
                        while end < lineEnd {
                            if !escaped(end) {
                                if bytes[end] == 40 { depth += 1 }
                                if bytes[end] == 41 { depth -= 1; if depth == 0 { break } }
                            }
                            end += 1
                        }
                        if depth == 0 {
                            let inside = substring(close + 2, end).trimmingCharacters(in: .whitespacesAndNewlines)
                            let target: String
                            if inside.hasPrefix("<") { target = String(inside.dropFirst().split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false)[0]) }
                            else { target = inside.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "" }
                            if let path = resolve(target: target, taskPath: taskPath, wiki: false, storePrefix: storePrefix) {
                                let label = unescape(substring(bracket + 1, close), punctuationOnly: true)
                                var targetStart = close + 2
                                while targetStart < end && [UInt16(32), 9, 13, 10].contains(bytes[targetStart]) { targetStart += 1 }
                                if targetStart < end && bytes[targetStart] == 60 { targetStart += 1 }
                                let pathPart = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
                                let destinationRange = NSRange(location: targetStart, length: String(pathPart).utf16.count)
                                results.append(Occurrence(range: NSRange(location: start, length: end + 1 - start), destinationRange: destinationRange, link: AttachmentLink(path: path, displayName: label, isImage: bytes[start] == 33)))
                            }
                            index = end + 1; continue
                        }
                    }
                }
                index = bracket + 1
            }
            offset = nextLine
        }
        return results
    }

    private static func unescape(_ value: String, punctuationOnly: Bool) -> String {
        let scalars = Array(value.unicodeScalars)
        var index = 0, result = ""
        while index < scalars.count {
            if scalars[index] == "\\" && index + 1 < scalars.count && (!punctuationOnly || (scalars[index + 1].isASCII && CharacterSet.punctuationCharacters.union(.symbols).contains(scalars[index + 1]))) { index += 1 }
            result.unicodeScalars.append(scalars[index]); index += 1
        }
        return result
    }

    private static func resolve(target: String, taskPath: String, wiki: Bool, storePrefix: String) -> String? {
        let target = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard var decoded = unescape(String(target), punctuationOnly: false).removingPercentEncoding else { return nil }
        if wiki && !storePrefix.isEmpty && decoded.hasPrefix(storePrefix + "/") { decoded = String(decoded.dropFirst(storePrefix.count + 1)) }
        guard !decoded.contains(":"), !decoded.hasPrefix("/"), !decoded.contains("\\"),
              decoded.hasPrefix("Attachments/") || decoded.hasPrefix("../") || decoded.hasPrefix("./") else { return nil }
        var components: [String] = wiki && decoded.hasPrefix(directory + "/") ? [] : taskPath.split(separator: "/").dropLast().map(String.init)
        for part in decoded.split(separator: "/", omittingEmptySubsequences: false) {
            if part == ".." { guard !components.isEmpty else { return nil }; components.removeLast() }
            else if part == "." || part.isEmpty { continue }
            else { components.append(String(part)) }
        }
        let path = components.joined(separator: "/")
        guard (try? validate(path: path)) != nil else { return nil }
        return path
    }
}
