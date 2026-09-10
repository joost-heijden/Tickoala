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
            TickoalaMenuBarIcon(isActive: model.status?.mode == .working)
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
    let isActive: Bool

    var body: some View {
        if let image = menuBarImage {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: isActive ? "clock.fill" : "circle")
        }
    }

    private var menuBarImage: NSImage? {
        let resourceName = isActive ? "tickoala-menu-active" : "tickoala-menu-idle"
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        return image
    }
}
