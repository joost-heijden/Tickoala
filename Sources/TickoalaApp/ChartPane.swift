import Charts
import SwiftUI
import TickoalaCore

/// The overview as a chart: hours per day, either one total bar per day or a
/// stacked bar split by project. Uses Apple's Swift Charts, which ships with the
/// system, so there is still no dependency.
struct ChartPane: View {
    @ObservedObject var model: AppModel
    @AppStorage("chart-stacked") private var stacked = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stacked ? "Hours per day, split by project" : "Hours per day")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Split by project", isOn: $stacked)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if model.overviewByDayProject.isEmpty {
                VStack {
                    Spacer()
                    Text("No work in this period.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                chart
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var chart: some View {
        Chart(model.overviewByDayProject) { row in
            BarMark(
                // A point x (not `unit: .day`) so the bar sits at the day and the
                // explicit day ticks line up with it. `foregroundStyle(by:)` alone
                // stacks the projects for one day.
                x: .value("Day", row.day),
                y: .value("Hours", row.seconds / 3600)
            )
            .foregroundStyle(by: stacked ? .value("Project", row.project) : .value("Project", "Hours"))
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text(Formatting.duration(hours * 3600))
                    }
                }
            }
        }
        .chartXAxis {
            // Mark one tick per day that actually has data. `automatic` can fall
            // back to hour ticks inside a single day, which reads as a time axis
            // instead of the day axis the bars are grouped by.
            AxisMarks(values: dayTicks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let day = value.as(Date.self) { Text(shortDay(day)) }
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
        .chartLegend(stacked ? .visible : .hidden)
        .frame(minHeight: 220)
    }

    /// Half-open day range so every bar sits in the middle of its day.
    private var xDomain: ClosedRange<Date> {
        let days = Set(model.overviewByDayProject.map(\.day)).sorted()
        let calendar = Formatting.calendar
        let first = (days.first ?? Date()).addingTimeInterval(-12 * 3600)
        let lastDay = days.last ?? Date()
        let endOfLast = calendar.startOfDay(for: lastDay).addingTimeInterval(36 * 3600)
        return first...endOfLast
    }

    /// Every day that has a bar, so the axis shows days and not hours.
    private var dayTicks: [Date] {
        Set(model.overviewByDayProject.map(\.day)).sorted()
    }

    private func shortDay(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: day)
    }
}
