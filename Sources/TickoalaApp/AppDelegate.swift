import AppKit
import Combine
import Foundation
import UserNotifications

/// Owns the `AppModel`.
///
/// The welcome screen is a regular SwiftUI `Window` scene. The menu bar label
/// opens it on first launch; wrapping it in a hand-made `NSWindow` caused an
/// AppKit layout exception when the window was reopened.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = AppModel()

    /// Key in UserDefaults; once seen means it never opens by itself again.
    static let welcomeSeenKey = "welcome-seen"

    /// The notification with the two answers to the network-switch question.
    static let switchCategory = "NETWORK_SWITCH"
    static let switchKeepAction = "SWITCH_KEEP"
    static let switchNewAction = "SWITCH_NEW"

    /// Watches for a network change that needs the user's answer.
    private var networkObserver: AnyCancellable?
    /// Whether the system allows notifications; otherwise the alert is the fallback.
    private var notificationsAllowed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        // SwiftUI may replace the main menu while the scenes come up, so put ours
        // back once the app is active.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reinstallMainMenu(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        configureNotifications()
        // The menu already offers the choice; the notification (or, if that is
        // not allowed, the alert) makes sure it is seen. Deferred, so the signal
        // handler finishes first.
        networkObserver = model.$pendingNetworkSwitch
            .compactMap { $0 }
            .sink { [weak self] pending in
                DispatchQueue.main.async { self?.announceSwitch(pending) }
            }
    }

    /// Sets up the notification buttons that answer the switch question.
    private func configureNotifications() {
        // A plain command-line run has no bundle and no notification centre.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let keep = UNNotificationAction(identifier: Self.switchKeepAction, title: "Keep running")
        let start = UNNotificationAction(identifier: Self.switchNewAction, title: "Start new block")
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.switchCategory, actions: [keep, start], intentIdentifiers: [], options: []
            )
        ])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.notificationsAllowed = granted }
        }
    }

    /// Asks continue-or-new when a block runs and the network changed to another
    /// customer. Prefers a quiet system notification; falls back to an alert when
    /// notifications are not permitted.
    private func announceSwitch(_ pending: AppModel.NetworkSwitch) {
        guard model.pendingNetworkSwitch == pending else { return }
        guard notificationsAllowed, Bundle.main.bundleIdentifier != nil else {
            presentSwitchAlert(pending)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Network changed to \(model.displayContext(pending.context))"
        content.body = "Now running: \(pending.runningLabel). Keep it running or start a new block?"
        content.categoryIdentifier = Self.switchCategory
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "network-switch-\(UUID().uuidString)", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Fallback when notifications are refused: a modal question, as before.
    private func presentSwitchAlert(_ pending: AppModel.NetworkSwitch) {
        guard model.pendingNetworkSwitch == pending else { return }
        let alert = NSAlert()
        alert.messageText = "Network changed to \(model.displayContext(pending.context))"
        alert.informativeText = "Now running: \(pending.runningLabel)"
        alert.addButton(withTitle: "Keep running")
        alert.addButton(withTitle: "Start new block")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.keepRunningAfterNetworkSwitch()
        } else {
            model.startNewBlockAfterNetworkSwitch()
        }
    }

    @objc private func reinstallMainMenu(_ notification: Notification) {
        installMainMenu()
    }

    /// An accessory app shows no menu bar, but a main menu still makes the
    /// standard shortcuts work (Cmd+Z, Cmd+C/V) while a window is open.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Tickoala", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        let undo = NSMenuItem(title: "Undo", action: #selector(undoChange(_:)), keyEquivalent: "z")
        undo.target = self
        editMenu.addItem(undo)

        let redo = NSMenuItem(title: "Redo", action: #selector(redoChange(_:)), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.target = self
        editMenu.addItem(redo)

        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    /// In a text field Cmd+Z takes back typing; everywhere else it takes back the
    /// last project or block change made in a window.
    @objc private func undoChange(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.undoManager?.canUndo == true {
            editor.undoManager?.undo()
        } else {
            model.undo()
        }
    }

    /// The mirror of `undoChange`.
    @objc private func redoChange(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.undoManager?.canRedo == true {
            editor.undoManager?.redo()
        } else {
            model.redo()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoChange(_:)) {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.undoManager?.canUndo == true {
                menuItem.title = "Undo Typing"
                return true
            }
            menuItem.title = model.canUndo ? "Undo \(model.undoTitle)" : "Undo"
            return model.canUndo
        }
        if menuItem.action == #selector(redoChange(_:)) {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.undoManager?.canRedo == true {
                menuItem.title = "Redo Typing"
                return true
            }
            menuItem.title = model.canRedo ? "Redo \(model.redoTitle)" : "Redo"
            return model.canRedo
        }
        return true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show the switch question as a banner even while Tickoala is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// The user answered the switch question from the notification.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == Self.switchKeepAction {
                model.keepRunningAfterNetworkSwitch()
            } else if action == Self.switchNewAction {
                model.startNewBlockAfterNetworkSwitch()
            }
            completionHandler()
        }
    }
}
