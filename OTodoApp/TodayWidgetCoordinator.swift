import OTodoCore
import WidgetKit

enum TodayWidgetCoordinator {
    static func synchronize(tasks: [TodoTask], states: [WorkflowState]) {
        let snapshot = TodayWidgetSnapshotBuilder.make(tasks: tasks, states: states)
        guard TodayWidgetStorage.save(snapshot) else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetStorage.widgetKind)
    }
}
