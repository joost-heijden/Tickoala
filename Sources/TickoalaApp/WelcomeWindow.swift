import AppKit
import SwiftUI
import TickoalaCore

/// First introduction: where Tickoala lives, why it needs Location Services and
/// how it starts automatically at login. Appears once on first launch and after
/// that via "Open Tickoala" in the menu.
struct WelcomeView: View {
    @ObservedObject var model: AppModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                intro
                wifiSection
                loginSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .frame(width: 460)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            koala
            VStack(alignment: .leading, spacing: 1) {
                Text("Tickoala")
                    .font(.title2.bold())
                Text("Background time tracking")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(model.updateChecker.currentVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(14)
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
        .frame(width: 36, height: 36)
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Tickoala lives in the menu bar")
                .font(.headline)
            Text("Look for the koala icon at the top right, next to the clock. "
                 + "Tracking starts and stops by itself with the customer's Wi-Fi — "
                 + "no buttons, no separate window.")
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
                 ?? "Set up. Tickoala only reads the Wi-Fi network name, nothing else.")
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
            Text("Tickoala can only watch Wi-Fi while it runs. "
                 + "Turn this on to start it after every restart.")
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
            Button("Get started") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
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
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(symbolColor)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}
