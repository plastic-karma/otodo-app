import Foundation

public enum TaskSortOrder: String, CaseIterable, Hashable, Sendable {
    case dueDate = "due-date"
    case createdDate = "created-date"
    case alphabetical

    public var title: String {
        switch self {
        case .dueDate: "Due date (earliest first)"
        case .createdDate: "Created date (newest first)"
        case .alphabetical: "Alphabetical (A–Z)"
        }
    }

    public func sort(
        _ tasks: inout [TodoTask], stateOrder: [String: Int], locale: Locale = .current
    ) {
        tasks.sort { lhs, rhs in
            switch self {
            case .createdDate:
                // Canonical ULIDs sort by their creation timestamp without decoding or new metadata.
                return lhs.id > rhs.id
            case .alphabetical:
                let comparison = lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric], locale: locale)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                return lhs.id < rhs.id
            case .dueDate:
                break
            }

            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }

            switch (lhs.dueTime, rhs.dueTime) {
            case let (left?, right?) where left != right:
                return left < right
            case (nil, _?):
                return true
            case (_?, nil):
                return false
            default:
                break
            }

            let lhsStateIndex = stateOrder[lhs.state] ?? Int.max
            let rhsStateIndex = stateOrder[rhs.state] ?? Int.max
            if lhsStateIndex != rhsStateIndex {
                return lhsStateIndex < rhsStateIndex
            }

            let lhsName = lhs.name.utf8
            let rhsName = rhs.name.utf8
            if !lhsName.elementsEqual(rhsName) {
                return lhsName.lexicographicallyPrecedes(rhsName)
            }
            return lhs.id < rhs.id
        }
    }
}
