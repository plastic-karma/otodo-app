import OTodoCore

/// Prepared sidebar counts, independent of the active filter, date, or project scope.
struct TaskListCounts {
    let open: Int
    let inbox: Int
    let byProject: [String: Int]

    init(tasks: [TodoTask], states: [WorkflowState]) {
        let terminalStateIDs = Set(states.lazy.filter(\.isTerminal).map(\.id))
        var open = 0
        var inbox = 0
        var byProject: [String: Int] = [:]
        var countedProjects: Set<String> = []
        for task in tasks where !terminalStateIDs.contains(task.state) {
            open += 1
            if task.projectSlugs.isEmpty {
                inbox += 1
            }
            countedProjects.removeAll(keepingCapacity: true)
            for project in task.projectSlugs where countedProjects.insert(project).inserted {
                byProject[project, default: 0] += 1
            }
        }
        self.open = open
        self.inbox = inbox
        self.byProject = byProject
    }
}
