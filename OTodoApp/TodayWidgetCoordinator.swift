import OTodoCore
import WidgetKit

enum TodayWidgetCoordinator {
    static func synchronize(snapshot: TodayWidgetSnapshot) {
        guard TodayWidgetStorage.save(snapshot) else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetStorage.widgetKind)
    }
}
