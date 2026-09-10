import SwiftUI
import WifiHoursCore

@main
struct WifiHoursApp: App {
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
        .defaultSize(width: 1000, height: 520)
    }
}
