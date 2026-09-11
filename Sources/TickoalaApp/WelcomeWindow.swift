import AppKit
import SwiftUI
import TickoalaCore

/// First introduction: where Tickoala lives, why it needs Location Services and
/// how it starts automatically at login. Appears once on first launch and after
/// that via "Open Tickoala" in the menu.
struct WelcomeView: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intro
                    wifiSection
                    loginSection
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            koala
            VStack(alignment: .leading, spacing: 2) {
                Text("Tickoala")
                    .font(.title.bold())
                Text("Background time tracking")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(model.updateChecker.currentVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(22)
    }

    private var koala: some View {
        Group {
            if let image = koalaImage {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "clock.badge.checkmark")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 46, height: 46)
        .foregroundStyle(Color.accentColor)
    }

    private var koalaImage: NSImage? {
        let theme = colorScheme == .dark ? "dark" : "light"
        guard let url = Bundle.module.url(
            forResource: "tickoala-menu-working-\(theme)",
            withExtension: "svg"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Explanation

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tickoala lives in the menu bar")
                .font(.headline)
            Text("You'll find it at the top right next to the clock, at the koala icon. "
                 + "You don't have to start anything: as soon as your Mac joins a customer's Wi-Fi network, "
                 + "tracking begins, and when you leave again it stops. "
                 + "A separate window isn't needed — everything is in that menu.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Location Services

    private var wifiSection: some View {
        SectionBox(
            title: "Location Services",
            symbol: model.wifi.access.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            symbolColor: model.wifi.access.needsAttention ? .orange : .green
        ) {
            Text(model.wifi.access.explanation
                 ?? "Access is set up. Tickoala only reads the name of the Wi-Fi network, and nothing else.")
                .fixedSize(horizontal: false, vertical: true)
            if model.wifi.access.needsAttention {
                Button("Grant access") {
                    NSApp.activate(ignoringOtherApps: true)
                    model.wifi.requestAccess()
                }
            }
        }
    }

    // MARK: - Start automatically

    private var loginSection: some View {
        SectionBox(title: "Start automatically", symbol: "power", symbolColor: .accentColor) {
            Toggle("Start Tickoala automatically at login", isOn: Binding(
                get: { model.launchAtLogin.isEnabled },
                set: { model.launchAtLogin.setEnabled($0) }
            ))
            Text("Tickoala can only watch Wi-Fi networks while it is running. "
                 + "With this option that happens automatically after every restart.")
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.launchAtLogin.errorMessage {
                Text(error)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items") {
                    model.launchAtLogin.openLoginItemsSettings()
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("You can find this screen later via **Open Tickoala** in the menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get started") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

/// A framed box with a heading, so the three topics on the welcome screen share
/// the same shape.
private struct SectionBox<Content: View>: View {
    let title: String
    let symbol: String
    let symbolColor: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(symbolColor)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Manages the welcome screen as a regular `NSWindow`. A SwiftUI `Window` scene
/// would only exist once you open it, and on first launch there is no view that
/// can do that; this way the app itself can show the window.
@MainActor
final class WelcomeWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: WelcomeView(model: model) { [weak self] in
                self?.window?.close()
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Tickoala"
        window.styleMask = [.titled, .closable]
        // Without this macOS releases the window on close, and then "Open
        // Tickoala" cannot show it again.
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("welcome-window")
        return window
    }
}
