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

    /// The notification that a newer version can be downloaded.
    static let updateCategory = "UPDATE_AVAILABLE"
    static let updateDownloadAction = "UPDATE_DOWNLOAD"

    /// Watches for a network change that needs the user's answer.
    private var networkObserver: AnyCancellable?
    /// Watches the version check so a new version is announced once.
    private var updateAnnounceObserver: AnyCancellable?
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
        // A window gives the app the menu bar; the last one closing returns it to
        // being a pure menu bar app without a Dock icon.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
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
        // A new version is easy to miss in a menu bar app, so say it out loud once.
        updateAnnounceObserver = model.updateChecker.$availableVersion
            .compactMap { $0 }
            .sink { [weak self] version in
                DispatchQueue.main.async { self?.announceUpdate(version) }
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
        let download = UNNotificationAction(identifier: Self.updateDownloadAction, title: "Download")
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.switchCategory, actions: [keep, start], intentIdentifiers: [], options: []
            ),
            UNNotificationCategory(
                identifier: Self.updateCategory, actions: [download], intentIdentifiers: [], options: []
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
        NSApp.activateForUI()
        if alert.runModal() == .alertFirstButtonReturn {
            model.keepRunningAfterNetworkSwitch()
        } else {
            model.startNewBlockAfterNetworkSwitch()
        }
    }

    /// Announces a newer version once, the first time it is seen. Tells the truth
    /// about the hard part: an unsigned (ad-hoc) build cannot get notification
    /// permission on macOS 26 at all, so when notifications are refused this falls
    /// back to an alert, which needs no permission. The menu keeps showing the item
    /// either way, and the decision stays with the user.
    private func announceUpdate(_ version: String) {
        // A plain command-line run has no bundle and no notification centre.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: UpdateChecker.notifiedVersionKey) != version else { return }
        defaults.set(version, forKey: UpdateChecker.notifiedVersionKey)

        guard notificationsAllowed else {
            presentUpdateAlert(version)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Tickoala \(version) is available"
        content.body = "Open the menu bar menu to update, or download it from the releases page."
        content.categoryIdentifier = Self.updateCategory
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "update-\(version)", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Fallback when notifications are refused, mirroring the network switch. A
    /// modal alert needs no permission, so it reaches users of an ad-hoc build too.
    private func presentUpdateAlert(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "Tickoala \(version) is available"
        alert.informativeText = "Download the new version from the releases page to update."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        NSApp.activateForUI()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(UpdateChecker.releasesURL)
        }
    }

    /// Clicking the Dock icon asks the app to reopen. Tickoala lives in the menu
    /// bar, so the window that belongs to the icon is Settings; open it again and
    /// suppress the standard behaviour, which would reopen the hub instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.requestSettingsWindow()
        return false
    }

    @objc private func reinstallMainMenu(_ notification: Notification) {
        installMainMenu()
    }

    /// Back to a pure menu bar app once the last window is gone. The short pause
    /// lets a window that is being opened from the menu settle first.
    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !NSApp.windows.contains(where: { $0.isVisible }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// An accessory app shows no menu bar, but a main menu still makes the
    /// standard shortcuts work (Cmd+Z, Cmd+C/V) while a window is open.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(title: "Tickoala", action: nil, keyEquivalent: "")
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

extension NSApplication {
    /// A menu bar app normally stays `.accessory`: no Dock icon, but also no menu
    /// bar of its own, so an opened window keeps the previously active app in the
    /// menu bar (and that app keeps focus). Switching to `.regular` for as long as
    /// a window is open gives Tickoala the menu bar; the temporary Dock icon
    /// disappears again once the last window closes.
    func activateForUI() {
        setActivationPolicy(.regular)
        activate(ignoringOtherApps: true)
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
        let category = response.notification.request.content.categoryIdentifier
        Task { @MainActor in
            if category == Self.updateCategory {
                // Both tapping the banner and the Download button lead to the
                // releases page, where the new build is waiting.
                NSWorkspace.shared.open(UpdateChecker.releasesURL)
            } else if action == Self.switchKeepAction {
                model.keepRunningAfterNetworkSwitch()
            } else if action == Self.switchNewAction {
                model.startNewBlockAfterNetworkSwitch()
            }
            completionHandler()
        }
    }
}
