import Charts
import SwiftUI
import TickoalaCore

/// The overview as a chart: hours (or the amount) per day, either one total bar
/// per day or a stacked bar split by project. Uses Apple's Swift Charts, which
/// ships with the system, so there is still no dependency.
struct ChartPane: View {
    @ObservedObject var model: AppModel
    @AppStorage("chart-stacked") private var stacked = true
    @AppStorage("chart-metric") private var metricRaw = Metric.hours.rawValue

    /// What the y-axis measures.
    private enum Metric: String {
        case hours
        case amount

        /// The value for one row, in the chart's own unit (hours or euros).
        func value(_ row: AppModel.DayProjectTotal) -> Double {
            switch self {
            case .hours: return row.seconds / 3600
            case .amount: return Double(row.cents) / 100
            }
        }

        var axisTitle: String { self == .hours ? "Hours" : "Amount" }
    }

    private var metric: Metric { Metric(rawValue: metricRaw) ?? .hours }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.chartHasAmount {
                    Picker("", selection: $metricRaw) {
                        Text("Hours").tag(Metric.hours.rawValue)
                        Text("Amount").tag(Metric.amount.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Show hours or the invoiced amount")
                }
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

    private var title: String {
        let what = metric == .hours ? "Hours per day" : "Amount per day"
        return stacked ? "\(what), split by project" : what
    }

    private var chart: some View {
        Chart(model.overviewByDayProject) { row in
            BarMark(
                // A point x (not `unit: .day`) so the bar sits at the day and the
                // explicit day ticks line up with it. `foregroundStyle(by:)` alone
                // stacks the projects for one day.
                x: .value("Day", row.day),
                y: .value(metric.axisTitle, metric.value(row))
            )
            .foregroundStyle(by: stacked ? .value("Project", row.project) : .value("Project", metric.axisTitle))
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(axisLabel(number))
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

    /// The y-axis label for one tick: `u:mm` for hours, an amount for money.
    private func axisLabel(_ number: Double) -> String {
        switch metric {
        case .hours: return Formatting.duration(number * 3600)
        case .amount: return Formatting.money(cents: Int((number * 100).rounded()), currency: model.chartCurrency)
        }
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
