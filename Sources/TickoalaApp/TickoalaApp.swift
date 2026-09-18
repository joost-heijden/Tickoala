import AppKit
import SwiftUI
import TickoalaCore

extension Bundle {
    /// Finds a resource in the packaged app first (`Contents/Resources`), then in
    /// the SwiftPM resource bundle for `swift run`. The packaged app must not use
    /// the latter: its resource bundle sat at the app root as a symlink, which
    /// makes `codesign` refuse to sign the bundle.
    static func tickoalaURL(forResource name: String, withExtension ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.module.url(forResource: name, withExtension: ext)
    }
}

@main
struct TickoalaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.menu)

        Window("Tickoala", id: "main") {
            MainWindow(model: appDelegate.model)
        }
        .defaultSize(width: 620, height: 620)

        Window("Settings", id: "settings") {
            SettingsWindow(model: appDelegate.model)
        }
        .defaultSize(width: 660, height: 560)

        Window("Welcome to Tickoala", id: "welcome") {
            WelcomeView(model: appDelegate.model)
        }
        .defaultSize(width: 460, height: 560)

        Window("Overview", id: "overview") {
            OverviewWindow(model: appDelegate.model)
        }
        .defaultSize(width: 1100, height: 560)

        Window("Projects", id: "projects") {
            ProjectsWindow(model: appDelegate.model)
        }
        .defaultSize(width: 760, height: 460)

        Window("Customers", id: "customers") {
            CustomersWindow(model: appDelegate.model)
        }
        .defaultSize(width: 820, height: 520)

        Window("Break settings", id: "break-settings") {
            BreakWindow(model: appDelegate.model)
        }
        .defaultSize(width: 560, height: 420)

        Window("Invoices", id: "invoices") {
            InvoicesWindow(model: appDelegate.model)
        }
        .defaultSize(width: 760, height: 560)

        Window("Invoice settings", id: "invoice-settings") {
            InvoiceSettingsWindow(model: appDelegate.model)
        }
        .defaultSize(width: 560, height: 620)
    }
}

/// The menu bar icon. On first launch it also opens the welcome screen, so that
/// no hand-made `NSWindow` is needed (that crashed when reopened).
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            TickoalaMenuBarIcon(mode: model.status?.mode ?? .stopped)
            if let earnings = model.menuBarEarnings {
                Text(earnings)
                    .monospacedDigit()
            }
        }
        .task {
            guard !UserDefaults.standard.bool(forKey: AppDelegate.welcomeSeenKey) else { return }
            UserDefaults.standard.set(true, forKey: AppDelegate.welcomeSeenKey)
            // Give the scenes a beat to come up before opening a window.
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.activateForUI()
            openWindow(id: "welcome")
        }
        // On the first weekday of the month the model asks for the invoices
        // window; open it once, then acknowledge.
        .onChange(of: model.shouldOpenInvoices) { shouldOpen in
            guard shouldOpen else { return }
            NSApp.activateForUI()
            openWindow(id: "invoices")
            model.acknowledgeInvoiceReminder()
        }
        // Clicking the Dock icon while a window is open asks for Settings;
        // bringing the window back is all that is needed.
        .onChange(of: model.shouldOpenSettings) { shouldOpen in
            guard shouldOpen else { return }
            NSApp.activateForUI()
            openWindow(id: "settings")
            model.acknowledgeSettingsWindow()
        }
    }
}

private struct TickoalaMenuBarIcon: View {
    let mode: TrackerMode

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = menuBarImage {
            Image(nsImage: image)
                .renderingMode(.original)
                .accessibilityLabel(accessibilityLabel)
        } else {
            Image(systemName: fallbackSymbol)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var menuBarImage: NSImage? {
        guard let url = Bundle.tickoalaURL(
            forResource: resourceName,
            withExtension: "svg"
        ) else {
            return nil
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        // The menu bar goes by the size of the image itself; a frame in SwiftUI
        // does nothing there. Without this line the icon arrives at the size from
        // the SVG (about 150 points wide) and runs far outside the bar. Only the
        // height is fixed, the width follows the ratio.
        let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
        image.size = NSSize(width: Self.menuBarHeight * ratio, height: Self.menuBarHeight)
        return image
    }

    /// Height in points; the menu bar itself is 22 points tall.
    private static let menuBarHeight: CGFloat = 17

    private var resourceName: String {
        "tickoala-menu-\(modeName)-\(themeName)"
    }

    private var modeName: String {
        switch mode {
        case .working: "working"
        case .paused: "paused"
        case .stopped: "stopped"
        case .attention: "attention"
        }
    }

    private var themeName: String {
        colorScheme == .dark ? "dark" : "light"
    }

    private var fallbackSymbol: String {
        switch mode {
        case .working: "clock.fill"
        case .paused: "pause.circle.fill"
        case .stopped: "circle"
        case .attention: "exclamationmark.circle.fill"
        }
    }

    private var accessibilityLabel: Text {
        switch mode {
        case .working: Text("Tickoala is tracking time")
        case .paused: Text("Tickoala is paused")
        case .stopped: Text("Tickoala is stopped")
        case .attention: Text("Tickoala needs attention")
        }
    }
}
