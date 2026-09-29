import SwiftUI
import TickoalaCore

/// The quarterly VAT return: turnover and VAT per rate, ready for the
/// Belastingdienst's form. Simple, local, and built from the same figures the
/// invoices show.
struct VATWindow: View {
    @ObservedObject var model: AppModel
    @State private var period = VATPeriod.containing(Date())

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { period = period.shifted(-1) } label: {
                Image(systemName: "chevron.left")
            }
            .help("Previous quarter")
            Text(period.label)
                .font(.headline)
                .monospacedDigit()
                .frame(width: 90)
            Button { period = period.shifted(1) } label: {
                Image(systemName: "chevron.right")
            }
            .help("Next quarter")

            Text(rangeLabel)
                .foregroundStyle(.secondary)

            Spacer()
            Button("This quarter") { period = VATPeriod.containing(Date()) }
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        let report = model.vatReport(for: period)
        if let report, !report.lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                row(header: true, rate: "Rate", net: "Turnover", vat: "VAT")
                Divider()
                ForEach(report.lines, id: \.ratePercent) { line in
                    row(
                        header: false,
                        rate: "\(line.ratePercent)%",
                        net: Formatting.money(cents: line.netCents),
                        vat: Formatting.money(cents: line.vatCents)
                    )
                    Divider()
                }
                row(
                    header: false,
                    rate: "Total",
                    net: Formatting.money(cents: report.totalNetCents),
                    vat: Formatting.money(cents: report.totalVatCents)
                )
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        } else {
            VStack(spacing: 8) {
                Spacer()
                Text("Nothing to declare for \(period.label).")
                    .font(.headline)
                Text("Only hours and expenses of euro customers with a rate count here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func row(header: Bool, rate: String, net: String, vat: String) -> some View {
        HStack {
            Text(rate)
                .frame(width: 70, alignment: .leading)
            Spacer()
            Text(net)
                .monospacedDigit()
                .frame(width: 140, alignment: .trailing)
            Text(vat)
                .monospacedDigit()
                .frame(width: 140, alignment: .trailing)
        }
        .font(header ? .headline : .body)
        .foregroundStyle(header ? .secondary : .primary)
        .padding(.vertical, 6)
    }

    private var rangeLabel: String {
        let last = period.end.addingTimeInterval(-86400)
        return "\(Formatting.day(period.start)) to \(Formatting.day(last))"
    }
}
