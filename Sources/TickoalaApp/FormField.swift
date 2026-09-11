import SwiftUI

/// A form row with a fixed label column on the left and the field directly after
/// it, text starting on the left. macOS' grouped form right-aligns text fields,
/// which reads right-to-left; these rows keep the input Western.
struct FormField<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 150
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
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
        .padding(.vertical, 2)
    }
}