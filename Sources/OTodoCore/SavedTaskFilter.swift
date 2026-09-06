import Foundation

public struct SavedTaskFilter: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let query: String
    public let isStarred: Bool

    public static let defaults: [SavedTaskFilter] = [
        SavedTaskFilter(builtInID: "today", name: "Today", query: "today"),
        SavedTaskFilter(builtInID: "active", name: "Active", query: "active"),
        SavedTaskFilter(builtInID: "all", name: "All", query: "all"),
        SavedTaskFilter(builtInID: "inbox", name: "Inbox", query: "inbox"),
    ]

    public var isBuiltIn: Bool {
        Self.defaults.contains { $0.id == id }
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        query: String,
        isStarred: Bool
    ) throws {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte)
                      || (48...57).contains(byte) || byte == 45 || byte == 95
              })
        else {
            throw OTodoError.validation(
                field: "filter.id",
                message: "Filter IDs must contain only letters, numbers, hyphens, or underscores"
            )
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.rangeOfCharacter(from: .newlines) == nil
        else {
            throw OTodoError.validation(
                field: "filter.name",
                message: "Filter name must be nonempty and single-line"
            )
        }
        if let builtIn = Self.defaults.first(where: { $0.id == id }) {
            guard name == builtIn.name, query == builtIn.query else {
                throw OTodoError.validation(
                    field: "filter",
                    message: "Built-in filter names and queries cannot be changed"
                )
            }
        }
        _ = try TaskFilterQuery(query)
        self.id = id
        self.name = name
        self.query = query
        self.isStarred = isStarred
    }

    private init(builtInID: String, name: String, query: String) {
        id = builtInID
        self.name = name
        self.query = query
        isStarred = true
    }

    private enum CodingKeys: String, CodingKey { case id, name, query, isStarred }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            query: container.decode(String.self, forKey: .query),
            isStarred: container.decode(Bool.self, forKey: .isStarred)
        )
    }
}
