import AppKit
import Combine
import Foundation
import ServiceManagement

/// Controls whether Tickoala starts automatically at login.
///
/// Tickoala is a menu bar app that watches Wi-Fi networks, but it can only do so
/// while running. Without a login item the user has to start it after every
/// restart before automatic tracking can do anything; this is the switch that
/// makes that work.
@MainActor
final class LaunchAtLogin: ObservableObject {
    /// Is the login item on? Follows the real system status, not just what we
    /// think we requested.
    @Published private(set) var isEnabled: Bool
    /// What went wrong when enabling or disabling, for the welcome screen.
    @Published private(set) var errorMessage: String?

    private let service = SMAppService.mainApp

    init() {
        isEnabled = service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
            isEnabled = service.status == .enabled
            // macOS can hold the request until the user approves it in System
            // Settings; that is not an error, but it is worth knowing, otherwise
            // the switch seems to flip back by itself.
            if enabled, service.status == .requiresApproval {
                errorMessage = "Turn Tickoala on under Login Items in System Settings."
            }
        } catch {
            errorMessage = "Could not change the login item: \(error.localizedDescription)"
            isEnabled = service.status == .enabled
        }
    }

    /// Opens the Login Items pane, in case macOS asks for approval.
    func openLoginItemsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
