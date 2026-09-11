import AppKit
import Foundation

/// Owns the `AppModel`.
///
/// The welcome screen is a regular SwiftUI `Window` scene. The menu bar label
/// opens it on first launch; wrapping it in a hand-made `NSWindow` caused an
/// AppKit layout exception when the window was reopened.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// Key in UserDefaults; once seen means it never opens by itself again.
    static let welcomeSeenKey = "welcome-seen"
}
