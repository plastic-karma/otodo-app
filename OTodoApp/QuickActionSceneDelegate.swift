import Combine
import Foundation
import UIKit

@MainActor
final class OTodoApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = QuickActionSceneDelegate.self
        }
        return configuration
    }
}

@MainActor
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject {
    static let newTodoType = "plastickarma.otodo.new-todo"

    @Published private(set) var pendingNewTodoRequestID: UUID?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard session.role == .windowApplication,
              let shortcutItem = connectionOptions.shortcutItem
        else {
            return
        }
        handle(shortcutItem)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem
    ) async -> Bool {
        handle(shortcutItem)
    }

    @discardableResult
    func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard shortcutItem.type == Self.newTodoType else { return false }
        pendingNewTodoRequestID = UUID()
        return true
    }

    func consumePendingNewTodoRequest() -> Bool {
        guard pendingNewTodoRequestID != nil else { return false }
        pendingNewTodoRequestID = nil
        return true
    }
}
