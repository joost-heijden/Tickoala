import AppKit
import Foundation

/// Owns the `AppModel` and the welcome screen.
///
/// The model belongs here rather than in the `App` struct: this way the app knows
/// at launch whether the welcome screen should be shown, before a SwiftUI view
/// exists to call `openWindow`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// Key in UserDefaults; once seen means it never opens by itself again.
    static let welcomeSeenKey = "welcome-seen"

    private var welcome: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        welcome = WelcomeWindowController(model: model)

        // Let the app model open the welcome screen from the menu.
        model.onShowWelcome = { [weak self] in self?.showWelcome() }

        // Only the very first launch: after that the screen can be opened from the
        // menu. Record it immediately, so a crash during the welcome doesn't loop.
        if !UserDefaults.standard.bool(forKey: Self.welcomeSeenKey) {
            UserDefaults.standard.set(true, forKey: Self.welcomeSeenKey)
            welcome?.show()
        }
    }

    func showWelcome() {
        welcome?.show()
    }
}
