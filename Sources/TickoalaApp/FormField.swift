import SwiftUI

/// A titled card with form rows. Replaces SwiftUI's grouped `Form`, which
/// right-aligns its controls on macOS and makes text start on the right.
struct FormSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

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
            .background(Color.gray.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        }
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