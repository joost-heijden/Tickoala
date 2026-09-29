import SwiftUI
import TickoalaCore

/// The overview as bars instead of a table: one row per day, each block drawn at
/// its real time. Drag a bar to move it, drag its right edge to change the end.
/// Corrections become visual; every change goes through the same undoable path
/// as the table.
///
/// The full day fits the window width, so nothing scrolls sideways and the day
/// labels stay put on the left.
struct TimelinePane: View {
    @ObservedObject var model: AppModel
    @Binding var selection: Int64?

    private let labelWidth: CGFloat = 92
    private let rowHeight: CGFloat = 28
    private let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let hourWidth = max(16, (geometry.size.width - labelWidth - 24) / 24)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: gap) {
                    ruler(hourWidth: hourWidth)
                    ForEach(days, id: \.self) { day in
                        dayRow(day, hourWidth: hourWidth)
                    }
                }
                .padding(10)
            }
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

    private func ruler(hourWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth)
            ZStack(alignment: .topLeading) {
                ForEach(Array(stride(from: 0, through: 24, by: 3)), id: \.self) { hour in
                    Text("\(hour)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .offset(x: CGFloat(hour) * hourWidth)
                }
            }
            .frame(width: 24 * hourWidth, height: 14, alignment: .topLeading)
        }
    }

    private func dayRow(_ day: Date, hourWidth: CGFloat) -> some View {
        let calendar = Formatting.calendar
        let rows = model.overviewEntries.filter { calendar.isDate($0.entry.startedAt, inSameDayAs: day) }
        let isWeekend = calendar.isDateInWeekend(day)
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(Formatting.day(day)).font(.caption).monospacedDigit()
                Text(weekday(day)).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: labelWidth, alignment: .trailing)
            .padding(.trailing, 6)

            ZStack(alignment: .topLeading) {
                grid(hourWidth: hourWidth, weekend: isWeekend)
                ForEach(rows) { row in
                    bar(row, day: day, hourWidth: hourWidth)
                }
            }
            .frame(width: 24 * hourWidth, height: rowHeight, alignment: .topLeading)
        }
    }

    private func grid(hourWidth: CGFloat, weekend: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(weekend ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.035))
            ForEach(0...24, id: \.self) { hour in
                Rectangle()
                    .fill(Color.primary.opacity(hour % 6 == 0 ? 0.18 : (hour % 3 == 0 ? 0.10 : 0.05)))
                    .frame(width: 1, height: rowHeight)
                    .offset(x: CGFloat(hour) * hourWidth)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func bar(_ row: AppModel.EntryRow, day: Date, hourWidth: CGFloat) -> some View {
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

    private func weekday(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter.string(from: day)
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

    /// A pleasant, stable colour per customer. The first is the accent colour, so
    /// a single client looks like the rest of the app.
    private static let palette: [Color] = [
        .accentColor, .teal, .indigo, .purple, .pink, .orange, .green, .mint, .cyan, .brown
    ]

    var body: some View {
        let startMinute = row.entry.startedAt.timeIntervalSince(day) / 60
        let end = row.entry.endedAt ?? Date()
        let minutes = max(4, end.timeIntervalSince(row.entry.startedAt) / 60)
        let baseX = CGFloat(startMinute) / 60 * hourWidth
        let baseWidth = max(6, CGFloat(minutes) / 60 * hourWidth)
        let x = baseX + moveX
        let width = max(6, baseWidth + resizeX)
        let draggable = row.entry.endedAt != nil

        RoundedRectangle(cornerRadius: 5)
            .fill(color.opacity(isSelected ? 1 : 0.88))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.white.opacity(0.9), lineWidth: isSelected ? 2 : 0)
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
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
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

    private var color: Color {
        Self.palette[Int(abs(row.entry.profileId) % Int64(Self.palette.count))]
    }
}
