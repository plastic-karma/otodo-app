import Foundation
import OTodoCore

enum TodayWidgetStorage {
    static let appGroupIdentifier = "group.plastickarma.otodo"
    static let widgetKind = "OTodoTodayWidget"

    private static let fileName = "today-widget.json"

    static func load() -> TodayWidgetSnapshot? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL)
        else {
            return nil
        }
        return try? JSONDecoder().decode(TodayWidgetSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: TodayWidgetSnapshot) -> Bool {
        guard let fileURL else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
