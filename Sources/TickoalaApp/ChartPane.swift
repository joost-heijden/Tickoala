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
                x: .value("Day", row.day, unit: .day),
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
            AxisMarks(values: .automatic(desiredCount: 8)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let day = value.as(Date.self) { Text(shortDay(day)) }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
        .chartLegend(stacked ? .visible : .hidden)
        .frame(minHeight: 220)
    }

    private func shortDay(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = model.period == .day ? "HH:mm" : "d MMM"
        return formatter.string(from: day)
    }

    private func duration(_ hours: Double) -> String {
        Formatting.duration(hours * 3600)
    }
}
