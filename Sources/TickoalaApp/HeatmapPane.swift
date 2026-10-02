import SwiftUI
import TickoalaCore

/// When you work: a weekday × hour grid, each cell shaded by how much net time
/// fell in it over the shown period. Drawn with plain SwiftUI rectangles, so it
/// needs no charting library and stays crisp at any size.
struct HeatmapPane: View {
    @ObservedObject var model: AppModel

    private let cell: CGFloat = 18
    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.heatmapCells.isEmpty {
                VStack {
                    Spacer()
                    Text("No work in this period.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    grid
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            Text("When you work")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                Text("less")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.2 + 0.2 * Double(step)))
                        .frame(width: 12, height: 12)
                }
                Text("more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var grid: some View {
        let values = Dictionary(
            uniqueKeysWithValues: model.heatmapCells.map { ($0.weekday * 24 + $0.hour, $0.seconds) }
        )
        let maxSeconds = max(1, model.heatmapCells.map(\.seconds).max() ?? 1)
        return VStack(alignment: .leading, spacing: gap) {
            // Hour ruler, a label every three hours to keep it readable.
            HStack(spacing: gap) {
                Color.clear.frame(width: labelWidth)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 3 == 0 ? "\(hour)" : "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: cell)
                }
            }
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: gap) {
                    Text(Self.dayName(day))
                        .font(.caption)
                        .foregroundStyle(day >= 5 ? .secondary : .primary)
                        .frame(width: labelWidth, alignment: .trailing)
                    ForEach(0..<24, id: \.self) { hour in
                        let seconds = values[day * 24 + hour] ?? 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(seconds: seconds, max: maxSeconds))
                            .frame(width: cell, height: cell)
                            .help(seconds > 0
                                ? "\(Self.dayName(day)) \(String(format: "%02d", hour)):00 — \(Formatting.duration(seconds))"
                                : "")
                    }
                }
            }
        }
    }

    private func color(seconds: TimeInterval, max maxSeconds: TimeInterval) -> Color {
        guard seconds > 0 else { return Color.primary.opacity(0.06) }
        let intensity = min(1, seconds / maxSeconds)
        return Color.accentColor.opacity(0.2 + 0.8 * intensity)
    }

    /// 0 = Monday … 6 = Sunday.
    private static func dayName(_ index: Int) -> String {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][max(0, min(6, index))]
    }
}
