import AppKit
import Foundation

/// Renders an invoice to a single A4 PDF page.
///
/// Deliberately one page: a month of one client is a handful of project lines.
/// ponytail: content taller than A4 is clipped, add pagination when a real
/// invoice ever needs more than ~20 lines.
public enum InvoicePDF {
    static let pageSize = NSSize(width: 595.276, height: 841.89) // A4 at 72 dpi

    /// Renders the invoice with the sender's stored logo, if there is one.
    public static func data(for invoice: Invoice) -> Data {
        data(for: invoice, logo: logoImage(invoice.sender))
    }

    public static func data(for invoice: Invoice, logo: NSImage?) -> Data {
        let view = InvoicePageView(invoice: invoice, logo: logo)
        view.frame = NSRect(origin: .zero, size: pageSize)
        return view.dataWithPDF(inside: view.bounds)
    }

    /// Loads the logo from Tickoala's support folder. `nil` when none is set or
    /// the file has since disappeared.
    public static func logoImage(_ settings: InvoiceSettings) -> NSImage? {
        guard let name = settings.logoFileName, !name.isEmpty,
              let directory = try? Store.supportDirectory() else { return nil }
        return NSImage(contentsOf: directory.appendingPathComponent(name))
    }
}

private final class InvoicePageView: NSView {
    private let invoice: Invoice
    private let logo: NSImage?

    private let margin: CGFloat = 50

    init(invoice: Invoice, logo: NSImage?) {
        self.invoice = invoice
        self.logo = logo
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Top-left origin, so layout reads top to bottom.
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        var y = margin
        y = drawHeader(at: y)
        y += 18
        y = drawBillTo(at: y)
        y += 22
        y = drawTable(at: y)
        y += 16
        y = drawTotals(at: y)
        y += 26
        drawFooter(at: y)
    }

    // MARK: - Header

    private func drawHeader(at top: CGFloat) -> CGFloat {
        let rightX = bounds.width - margin
        var leftY = top

        if let logo {
            let size = fittedSize(of: logo, maxWidth: 190, maxHeight: 70)
            logo.draw(in: NSRect(x: margin, y: leftY, width: size.width, height: size.height))
            leftY += size.height + 12
        }

        var senderLines = [invoice.sender.senderName]
        senderLines.append(contentsOf: nonEmptyLines(invoice.sender.senderAddress))
        if !invoice.sender.senderKvk.isEmpty { senderLines.append("KvK \(invoice.sender.senderKvk)") }
        if !invoice.sender.senderVatNumber.isEmpty { senderLines.append("VAT \(invoice.sender.senderVatNumber)") }
        if !invoice.sender.senderEmail.isEmpty { senderLines.append(invoice.sender.senderEmail) }
        if !invoice.sender.senderIban.isEmpty { senderLines.append("IBAN \(invoice.sender.senderIban)") }

        for line in senderLines where !line.isEmpty {
            leftY += draw(line, x: margin, y: leftY, width: 280, font: .systemFont(ofSize: 9), color: .darkGray)
        }

        var rightY = top
        rightY += draw("INVOICE", x: rightX - 240, y: rightY, width: 240, font: .boldSystemFont(ofSize: 24), alignment: .right)
        rightY += 6

        let meta: [(String, String)] = [
            ("Invoice number", invoice.number),
            ("Invoice date", Formatting.day(invoice.issuedAt)),
            ("Period", "\(Formatting.day(invoice.periodStart)) – \(Formatting.day(invoice.periodEnd.addingTimeInterval(-86400)))"),
            ("Due date", Formatting.day(invoice.dueAt)),
        ] + (invoice.poNumber.map { [("PO number", $0)] } ?? [])

        for (label, value) in meta {
            let line = "\(label):  \(value)"
            rightY += draw(line, x: rightX - 240, y: rightY, width: 240, font: .systemFont(ofSize: 9), alignment: .right)
        }

        let bottom = max(leftY, rightY)
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: margin, y: bottom + 8))
        rule.line(to: NSPoint(x: rightX, y: bottom + 8))
        NSColor(white: 0.75, alpha: 1).setStroke()
        rule.lineWidth = 1
        rule.stroke()
        return bottom + 8
    }

    // MARK: - Bill to

    private func drawBillTo(at top: CGFloat) -> CGFloat {
        var y = top
        y += draw("Bill to", x: margin, y: y, width: 300, font: .boldSystemFont(ofSize: 9), color: .darkGray)
        y += 2
        y += draw(invoice.profile.name, x: margin, y: y, width: 300, font: .boldSystemFont(ofSize: 11))
        for line in nonEmptyLines(invoice.profile.billingAddress) {
            y += draw(line, x: margin, y: y, width: 300, font: .systemFont(ofSize: 10))
        }
        if let vat = invoice.profile.vatNumber, !vat.isEmpty {
            y += draw("VAT \(vat)", x: margin, y: y, width: 300, font: .systemFont(ofSize: 10), color: .darkGray)
        }
        return y
    }

    // MARK: - Table

    private let descX: CGFloat = 50
    private let hoursX: CGFloat = 295
    private let rateX: CGFloat = 365
    private let amountX: CGFloat = 435
    private let colWidth: CGFloat = 110
    private let hoursWidth: CGFloat = 65
    private let rateWidth: CGFloat = 65

    private func drawTable(at top: CGFloat) -> CGFloat {
        var y = top

        let headerFont = NSFont.boldSystemFont(ofSize: 9)
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(x: margin, y: y - 3, width: bounds.width - 2 * margin, height: 17).fill()
        _ = draw("Description", x: descX, y: y, width: hoursX - descX - 8, font: headerFont)
        _ = draw("Hours", x: hoursX, y: y, width: hoursWidth, font: headerFont, alignment: .right)
        _ = draw("Rate", x: rateX, y: y, width: rateWidth, font: headerFont, alignment: .right)
        _ = draw("Amount", x: amountX, y: y, width: colWidth, font: headerFont, alignment: .right)
        y += 24

        for line in invoice.lines {
            let bodyFont = NSFont.systemFont(ofSize: 10)
            let amount = Formatting.money(cents: line.amountCents, currency: invoice.currency)
            let rowHeight = max(
                measured(line.label, width: hoursX - descX - 8, font: bodyFont),
                measured(amount, width: colWidth, font: bodyFont)
            )
            _ = draw(line.label, x: descX, y: y, width: hoursX - descX - 8, font: bodyFont)
            let hours = line.seconds < 0
                ? "-" + Formatting.decimalHours(-line.seconds)
                : Formatting.decimalHours(line.seconds)
            _ = draw(hours, x: hoursX, y: y, width: hoursWidth, font: bodyFont, alignment: .right)
            if line.hourlyRateCents > 0 {
                _ = draw(Formatting.money(cents: line.hourlyRateCents, currency: invoice.currency), x: rateX, y: y, width: rateWidth, font: bodyFont, alignment: .right)
            }
            _ = draw(amount, x: amountX, y: y, width: colWidth, font: bodyFont, alignment: .right)
            y += rowHeight + 6
        }

        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: margin, y: y))
        rule.line(to: NSPoint(x: bounds.width - margin, y: y))
        NSColor(white: 0.85, alpha: 1).setStroke()
        rule.lineWidth = 1
        rule.stroke()
        return y + 6
    }

    // MARK: - Totals

    private func drawTotals(at top: CGFloat) -> CGFloat {
        var y = top
        let labelX: CGFloat = 305
        let labelWidth: CGFloat = 130

        func row(_ label: String, _ value: String, font: NSFont) -> CGFloat {
            let height = max(measured(label, width: labelWidth, font: font), measured(value, width: colWidth, font: font))
            _ = draw(label, x: labelX, y: y, width: labelWidth, font: font, alignment: .right)
            _ = draw(value, x: amountX, y: y, width: colWidth, font: font, alignment: .right)
            return height
        }

        y += row("Subtotal", Formatting.money(cents: invoice.subtotalCents, currency: invoice.currency), font: .systemFont(ofSize: 10)) + 6
        y += row("VAT \(invoice.vatRatePercent)%", Formatting.money(cents: invoice.vatCents, currency: invoice.currency), font: .systemFont(ofSize: 10)) + 6
        y += row("Total", Formatting.money(cents: invoice.totalCents, currency: invoice.currency), font: .boldSystemFont(ofSize: 12)) + 4
        return y
    }

    // MARK: - Footer

    private func drawFooter(at top: CGFloat) {
        var lines = ["Please pay the total within \(invoice.sender.paymentTermDays) days, before \(Formatting.day(invoice.dueAt))."]
        if !invoice.sender.senderIban.isEmpty {
            lines.append("Transfer to IBAN \(invoice.sender.senderIban), quoting invoice number \(invoice.number).")
        }
        var y = top
        for line in lines {
            y += draw(line, x: margin, y: y, width: bounds.width - 2 * margin, font: .systemFont(ofSize: 9), color: .darkGray)
        }
    }

    // MARK: - Drawing helpers

    @discardableResult
    private func draw(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        font: NSFont,
        color: NSColor = .black,
        alignment: NSTextAlignment = .left
    ) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
        let height = measured(text, width: width, font: font)
        attributed.draw(with: NSRect(x: x, y: y, width: width, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return height
    }

    private func measured(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let bounds = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(max(bounds.height, font.ascender - font.descender + font.leading))
    }

    private func nonEmptyLines(_ text: String?) -> [String] {
        (text ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func fittedSize(of image: NSImage, maxWidth: CGFloat, maxHeight: CGFloat) -> NSSize {
        guard image.size.height > 0, image.size.width > 0 else { return NSSize(width: maxWidth, height: maxHeight) }
        let scale = min(maxWidth / image.size.width, maxHeight / image.size.height, 1)
        return NSSize(width: image.size.width * scale, height: image.size.height * scale)
    }
}