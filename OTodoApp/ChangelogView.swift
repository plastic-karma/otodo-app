import Foundation
import SwiftUI

struct ChangelogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var content: Content = .loading

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            List {
                switch content {
                case .loading:
                    ProgressView("Loading changelog…")
                case let .loaded(entries):
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.title)
                                .font(.subheadline.weight(.medium))
                            Text(
                                Self.timestampFormatter.string(
                                    from: Date(timeIntervalSince1970: TimeInterval(entry.timestamp))
                                )
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("changelog-timestamp")
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("changelog-entry-\(entry.commit)")
                    }
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(OTodoCanvas())
            .navigationTitle("Changelog")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("changelog-list")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("changelog-close")
                }
            }
            .task {
                guard case .loading = content else { return }
                do {
                    guard let url = Bundle.main.url(forResource: "Changelog", withExtension: "json") else {
                        throw ChangelogError.missingResource
                    }
                    let data = try Data(contentsOf: url)
                    content = .loaded(try JSONDecoder().decode([Entry].self, from: data))
                } catch {
                    content = .failed("Unable to load changelog: \(error.localizedDescription)")
                }
            }
        }
    }

    private struct Entry: Decodable, Identifiable {
        let commit: String
        let timestamp: Int64
        let title: String

        var id: String { commit }
    }

    private enum Content {
        case loading
        case loaded([Entry])
        case failed(String)
    }

    private enum ChangelogError: LocalizedError {
        case missingResource

        var errorDescription: String? {
            "Changelog.json is missing from the app bundle."
        }
    }
}
