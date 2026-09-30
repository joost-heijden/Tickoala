import AppKit
import SwiftUI

extension NSColor {
    /// The app's window background: white in light mode, the system colour in
    /// dark mode. Shared so every window and the customer list's sidebar match.
    static let tickoalaWindow = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .windowBackgroundColor
            : .white
    }
}

extension View {
    /// Fills the window behind the content: white in light mode, the system
    /// background in dark mode and with increased contrast. SwiftUI's hosting
    /// view does not honour `NSWindow.backgroundColor`, so every window root
    /// paints this itself.
    func tickoalaWindowBackground() -> some View {
        modifier(TickoalaWindowBackground())
    }
}

private struct TickoalaWindowBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            (scheme == .dark || contrast == .increased
                ? Color(nsColor: .windowBackgroundColor)
                : Color.white)
                .ignoresSafeArea()
        }
    }
}

/// A titled card with form rows. Replaces SwiftUI's grouped `Form`, which
/// right-aligns its controls on macOS and makes text start on the right.
struct FormSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 10))
            // Increased contrast gets a hairline so the card edge stays visible.
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.primary.opacity(contrast == .increased ? 0.3 : 0), lineWidth: 1)
            )
        }
    }

    private var cardColor: Color {
        Color.gray.opacity(contrast == .increased ? 0.16 : 0.09)
    }
}

/// A form row with a fixed label column on the left and the field directly after
/// it, text starting on the left.
struct FormField<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 150
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: labelWidth, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                // VoiceOver otherwise reaches the field without a name.
                .accessibilityLabel(label)
        }
    }
}

/// The same, for long values such as an address: the label sits above a field
/// that spans the full width.
struct FormFieldStacked<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(label)
        }
    }
}

/// Left-aligned text field used inside `FormField` and `FormFieldStacked`.
struct FormTextField: View {
    let text: Binding<String>
    var prompt: String?

    var body: some View {
        TextField("", text: text, prompt: prompt.map(Text.init))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
    }
}