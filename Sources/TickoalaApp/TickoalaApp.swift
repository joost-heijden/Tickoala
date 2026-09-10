import SwiftUI
import TickoalaCore

@main
struct TickoalaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // Klok bij een lopende timer, anders een kort statuswoord.
            Label(model.menuBarTitle, systemImage: model.menuBarSymbol)
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
