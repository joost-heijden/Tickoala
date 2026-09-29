import SwiftUI
import TickoalaCore

/// The overview as bars instead of a table: one row per day, each block drawn at
/// its real time. Drag a bar to move it, drag its right edge to change the end.
/// Corrections become visual; every change goes through the same undoable path
/// as the table.
struct TimelinePane: View {
    @ObservedObject var model: AppModel
    @Binding var selection: Int64?

    private let hourWidth: CGFloat = 52
    private let rowHeight: CGFloat = 34
    private let labelWidth: CGFloat = 74

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(days, id: \.self) { day in
                    dayRow(day)
                }
            }
            .padding(8)
        }
    }

    /// Start-of-day for every day in the shown window. Bounded, so a strange range
    /// cannot spin forever.
    private var days: [Date] {
        let calendar = Formatting.calendar
        var result: [Date] = []
        var day = calendar.startOfDay(for: model.overviewRange.start)
        let end = model.overviewRange.end
        while day < end, result.count < 62 {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    private func dayRow(_ day: Date) -> some View {
        let calendar = Formatting.calendar
        let rows = model.overviewEntries.filter { calendar.isDate($0.entry.startedAt, inSameDayAs: day) }
        let isWeekend = calendar.isDateInWeekend(day)
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(Formatting.day(day)).font(.callout).monospacedDigit()
                if isWeekend {
                    Text("weekend").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: labelWidth, alignment: .trailing)

            ZStack(alignment: .topLeading) {
                hourGrid
                ForEach(rows) { row in
                    bar(row, day: day)
                }
            }
            .frame(width: 24 * hourWidth, height: rowHeight)
        }
    }

    private var hourGrid: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .underPageBackgroundColor))
            ForEach(0...24, id: \.self) { hour in
                Rectangle()
                    .fill(Color.secondary.opacity(hour % 6 == 0 ? 0.35 : 0.15))
                    .frame(width: 1, height: rowHeight)
                    .offset(x: CGFloat(hour) * hourWidth)
            }
        }
    }

    @ViewBuilder
    private func bar(_ row: AppModel.EntryRow, day: Date) -> some View {
        TimelineBar(
            row: row,
            day: day,
            hourWidth: hourWidth,
            rowHeight: rowHeight,
            isSelected: selection == row.id,
            onSelect: { selection = row.id },
            onMove: { model.shiftEntry(id: row.id, minutes: $0) },
            onResize: { model.resizeEntryEnd(id: row.id, minutes: $0) }
        )
    }
}

/// One draggable block. Moving shifts start and end together; the trailing strip
/// changes only the end.
private struct TimelineBar: View {
    let row: AppModel.EntryRow
    let day: Date
    let hourWidth: CGFloat
    let rowHeight: CGFloat
    let isSelected: Bool
    let onSelect: () -> Void
    let onMove: (Int) -> Void
    let onResize: (Int) -> Void

    @GestureState private var moveX: CGFloat = 0
    @GestureState private var resizeX: CGFloat = 0

    var body: some View {
        let startMinute = row.entry.startedAt.timeIntervalSince(day) / 60
        let end = row.entry.endedAt ?? Date()
        let minutes = max(4, end.timeIntervalSince(row.entry.startedAt) / 60)
        let baseX = CGFloat(startMinute) / 60 * hourWidth
        let baseWidth = max(6, CGFloat(minutes) / 60 * hourWidth)
        let x = baseX + moveX
        let width = max(6, baseWidth + resizeX)
        let draggable = row.entry.endedAt != nil

        RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(isSelected ? 1 : 0.75))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
            )
            .overlay(alignment: .leading) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
            .frame(width: width, height: rowHeight - 6)
            .offset(x: x, y: 3)
            .onTapGesture(perform: onSelect)
            .gesture(
                DragGesture(minimumDistance: 3)
                    .updating($moveX) { value, state, _ in state = value.translation.width }
                    .onEnded { value in
                        onMove(Int((value.translation.width / hourWidth * 60).rounded()))
                    }
            )
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(.white.opacity(0.001))
                    .frame(width: 8, height: rowHeight - 6)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 3)
                            .updating($resizeX) { value, state, _ in state = value.translation.width }
                            .onEnded { value in
                                onResize(Int((value.translation.width / hourWidth * 60).rounded()))
                            }
                    )
            }
            .allowsHitTesting(draggable)
            .help(row.entry.note ?? "")
    }

    private var label: String {
        let start = Formatting.clock(row.entry.startedAt)
        let end = row.entry.endedAt.map(Formatting.clock) ?? "…"
        let kind = row.entry.kind == .work ? "" : " \(row.entry.kind.label)"
        return "\(start)–\(end)\(kind)"
    }

    /// A stable colour per customer, so blocks of the same client look alike.
    private var color: Color {
        let hue = Double(abs(row.entry.profileId % 12)) / 12.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }
}
