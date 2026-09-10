import AppKit
import SwiftUI
import TickoalaCore

@main
struct TickoalaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            TickoalaMenuBarIcon(mode: model.status?.mode ?? .stopped)
        }
        .menuBarExtraStyle(.menu)

        Window("Overzicht", id: "overzicht") {
            OverviewWindow(model: model)
        }
        .defaultSize(width: 1100, height: 560)

        Window("Projecten", id: "projecten") {
            ProjectsWindow(model: model)
        }
        .defaultSize(width: 760, height: 460)

        Window("Pauze-instellingen", id: "pauze") {
            BreakWindow(model: model)
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
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
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
        return NSImage(contentsOf: url)
    }

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
        case .working: Text("Tickoala registreert uren")
        case .paused: Text("Tickoala is gepauzeerd")
        case .stopped: Text("Tickoala is gestopt")
        case .attention: Text("Tickoala heeft aandacht nodig")
        }
    }
}
