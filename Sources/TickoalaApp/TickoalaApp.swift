import AppKit
import SwiftUI
import TickoalaCore

@main
struct TickoalaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            TickoalaMenuBarIcon(mode: appDelegate.model.status?.mode ?? .stopped)
        }
        .menuBarExtraStyle(.menu)

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
        guard let url = Bundle.module.url(
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
