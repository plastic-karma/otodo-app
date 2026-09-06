import Foundation

public struct TaskHierarchyIssue: Sendable, Equatable {
    public let code: String
    public let taskID: TaskID
    public let parentID: TaskID?
    public let message: String
}

public struct TaskHierarchyRow: Sendable, Equatable {
    public let task: TodoTask
    public let depth: Int
}

public struct TaskRelationshipBlock: Codable, Sendable, Equatable {
    public let path: String
    public let code: String
    public let message: String
    public let relatedTaskIDs: [TaskID]

    public init(path: String, code: String, message: String, relatedTaskIDs: [TaskID]) {
        self.path = path
        self.code = code
        self.message = message
        self.relatedTaskIDs = relatedTaskIDs
    }
}

/// A disposable identity index. Faulty edges stay in the records, never become persisted roots.
public struct TaskHierarchy: Sendable {
    public let issues: [TaskHierarchyIssue]
    private let tasksByID: [TaskID: TodoTask]
    private let childrenByID: [TaskID: [TodoTask]]

    public init(tasks: [TodoTask]) {
        let groups = Dictionary(grouping: tasks, by: \.id)
        let unique = groups.compactMapValues { $0.count == 1 ? $0[0] : nil }
        var children: [TaskID: [TodoTask]] = [:]
        var found: [TaskHierarchyIssue] = []
        for (id, records) in groups where records.count > 1 {
            found.append(TaskHierarchyIssue(code: "duplicate_task_id", taskID: id, parentID: nil,
                                            message: "More than one record has identity \(id.rawValue)"))
        }
        for task in unique.values {
            guard let parent = task.parentID else { continue }
            children[parent, default: []].append(task)
            if parent == task.id {
                found.append(TaskHierarchyIssue(code: "self_parent_reference", taskID: task.id, parentID: parent,
                                                message: "A task cannot be its own parent"))
            } else if groups[parent] == nil {
                found.append(TaskHierarchyIssue(code: "missing_parent_reference", taskID: task.id, parentID: parent,
                                                message: "Parent \(parent.rawValue) is missing"))
            }
        }
        // Each edge is visited once. A walk stops at an ambiguous identity rather than choosing a record.
        var finished: Set<TaskID> = []
        for start in unique.keys.sorted() where !finished.contains(start) {
            var walk: [TaskID] = []
            var positions: [TaskID: Int] = [:]
            var next: TaskID? = start
            while let id = next, let task = unique[id], !finished.contains(id) {
                if let position = positions[id] {
                    let cycle = walk[position...]
                    if cycle.count > 1 {
                        for member in cycle {
                            found.append(TaskHierarchyIssue(code: "parent_cycle", taskID: member,
                                                            parentID: unique[member]?.parentID,
                                                            message: "Task belongs to a parent cycle"))
                        }
                    }
                    break
                }
                positions[id] = walk.count
                walk.append(id)
                next = task.parentID
            }
            finished.formUnion(walk)
        }
        self.tasksByID = unique
        self.childrenByID = children.mapValues { $0.sorted { $0.id < $1.id } }
        self.issues = found.sorted { $0.taskID == $1.taskID ? $0.code < $1.code : $0.taskID < $1.taskID }
    }

    public func task(for id: TaskID) -> TodoTask? { tasksByID[id] }
    public func children(of id: TaskID) -> [TodoTask] { childrenByID[id] ?? [] }

    public func ancestorIDs(of id: TaskID) -> [TaskID] {
        var result: [TaskID] = []
        var visited: Set<TaskID> = [id]
        var next = tasksByID[id]?.parentID
        while let parent = next, visited.insert(parent).inserted {
            result.append(parent)
            next = tasksByID[parent]?.parentID
        }
        result.reverse()
        return result
    }

    public func descendantIDs(of id: TaskID) -> Set<TaskID> {
        var visited: Set<TaskID> = [id]
        var stack = [id]
        while let next = stack.popLast() {
            for child in children(of: next) where visited.insert(child.id).inserted {
                stack.append(child.id)
            }
        }
        visited.remove(id)
        return visited
    }

    /// Input order supplies the existing root/sibling comparator; no unmatched context is inserted.
    public func rows(matching matches: [TodoTask]) -> [TaskHierarchyRow] {
        let ids = Set(matches.map(\.id))
        var children: [TaskID: [TodoTask]] = [:]
        var roots: [TodoTask] = []
        for task in matches {
            if let parent = task.parentID, ids.contains(parent), tasksByID[parent] != nil, parent != task.id {
                children[parent, default: []].append(task)
            } else {
                roots.append(task)
            }
        }
        var visited: Set<TaskID> = []
        var result: [TaskHierarchyRow] = []
        // The second pass visits rootless cycles and their descendants exactly once.
        for root in roots + matches where !visited.contains(root.id) {
            var stack = [(root, 0)]
            while let (task, depth) = stack.popLast() {
                guard visited.insert(task.id).inserted else { continue }
                result.append(TaskHierarchyRow(task: task, depth: depth))
                for child in (children[task.id] ?? []).reversed() { stack.append((child, depth + 1)) }
            }
        }
        return result
    }

    /// Related components are undirected so a withheld detach/creation also protects its dependents.
    static func connectedIDs(to seeds: Set<TaskID>, tasks: [TodoTask]) -> Set<TaskID> {
        var neighbors: [TaskID: Set<TaskID>] = [:]
        for task in tasks {
            if let parent = task.parentID {
                neighbors[task.id, default: []].insert(parent)
                neighbors[parent, default: []].insert(task.id)
            }
        }
        var result = seeds
        var stack = Array(seeds)
        while let id = stack.popLast() {
            for neighbor in neighbors[id] ?? [] where result.insert(neighbor).inserted { stack.append(neighbor) }
        }
        return result
    }

    static func blocks(tasks: [TodoTask], storePath: String) -> [TaskRelationshipBlock] {
        let hierarchy = TaskHierarchy(tasks: tasks)
        guard !hierarchy.issues.isEmpty else { return [] }
        var neighbors: [TaskID: Set<TaskID>] = [:]
        for task in tasks {
            if let parent = task.parentID {
                neighbors[task.id, default: []].insert(parent)
                neighbors[parent, default: []].insert(task.id)
            }
        }
        // Each component is traversed and sorted once; arrays share storage across member diagnostics.
        var components: [TaskID: [TaskID]] = [:]
        for issue in hierarchy.issues where components[issue.taskID] == nil {
            var ids: Set<TaskID> = [issue.taskID]
            var stack = [issue.taskID]
            while let id = stack.popLast() {
                for neighbor in neighbors[id] ?? [] where ids.insert(neighbor).inserted {
                    stack.append(neighbor)
                }
            }
            let ordered = ids.sorted()
            for id in ids { components[id] = ordered }
        }
        return hierarchy.issues.map { issue in
            let relativePath = hierarchy.task(for: issue.taskID)?.relativePath ?? issue.taskID.rawValue
            return TaskRelationshipBlock(
                path: storePath.isEmpty ? relativePath : storePath + "/" + relativePath,
                code: issue.code, message: issue.message,
                relatedTaskIDs: components[issue.taskID] ?? [issue.taskID]
            )
        }
    }
}
