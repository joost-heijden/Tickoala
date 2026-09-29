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

/// Reads and writes the stored accent as `#RRGGBB`. `nil` for an empty or
/// unreadable string, so the caller falls back to the greyscale default. Shared
/// with the settings UI, which is why it is public.
public enum InvoiceAccent {
    public static func color(hex: String?) -> NSColor? {
        let text = (hex ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    public static func hex(from color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(srgb.redComponent), channel(srgb.greenComponent), channel(srgb.blueComponent))
    }
}

/// The invoice palette. Body text, panels and hairlines are neutral greys;
/// `accent` colours the title, the header rule, the table header and the total
/// line. With no accent configured it falls back to near-black — the plain
/// greyscale look.
private struct InvoicePalette {
    let accent: NSColor
    static let ink = NSColor(white: 0.13, alpha: 1)
    static let muted = NSColor(white: 0.42, alpha: 1)
    static let panel = NSColor(white: 0.945, alpha: 1)
    static let hairline = NSColor(white: 0.84, alpha: 1)

    init(accentHex: String?) {
        accent = InvoiceAccent.color(hex: accentHex) ?? InvoicePalette.ink
    }
}

private final class InvoicePageView: NSView {
    private let invoice: Invoice
    private let logo: NSImage?
    private let palette: InvoicePalette

    private let margin: CGFloat = 50

    init(invoice: Invoice, logo: NSImage?) {
        self.invoice = invoice
        self.logo = logo
        self.palette = InvoicePalette(accentHex: invoice.sender.accentColorHex)
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

        // A single accent rule along the top edge, for structure.
        palette.accent.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 4).fill()

        var y = margin + 6
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

        leftY += draw(invoice.sender.senderName, x: margin, y: leftY, width: 280, font: .boldSystemFont(ofSize: 10), color: InvoicePalette.ink)

        var senderLines = nonEmptyLines(invoice.sender.senderAddress)
        if !invoice.sender.senderKvk.isEmpty { senderLines.append("KvK \(invoice.sender.senderKvk)") }
        if !invoice.sender.senderVatNumber.isEmpty { senderLines.append("VAT \(invoice.sender.senderVatNumber)") }
        if !invoice.sender.senderEmail.isEmpty { senderLines.append(invoice.sender.senderEmail) }
        if !invoice.sender.senderIban.isEmpty { senderLines.append("IBAN \(invoice.sender.senderIban)") }

        for line in senderLines where !line.isEmpty {
            leftY += draw(line, x: margin, y: leftY, width: 280, font: .systemFont(ofSize: 9), color: InvoicePalette.muted)
        }

        var rightY = top
        rightY += draw("INVOICE", x: rightX - 240, y: rightY, width: 240, font: .boldSystemFont(ofSize: 22), color: palette.accent, alignment: .right, kern: 3)
        rightY += 8

        let meta: [(String, String)] = [
            ("Invoice number", invoice.number),
            ("Invoice date", Formatting.day(invoice.issuedAt)),
            ("Period", "\(Formatting.day(invoice.periodStart)) – \(Formatting.day(invoice.periodEnd.addingTimeInterval(-86400)))"),
            ("Due date", Formatting.day(invoice.dueAt)),
        ] + (invoice.poNumber.map { [("PO number", $0)] } ?? [])

        for (label, value) in meta {
            let height = max(
                draw(label, x: rightX - 240, y: rightY, width: 240, font: .systemFont(ofSize: 9), color: InvoicePalette.muted, alignment: .left),
                draw(value, x: rightX - 240, y: rightY, width: 240, font: .boldSystemFont(ofSize: 9), color: InvoicePalette.ink, alignment: .right)
            )
            rightY += height
        }

        let bottom = max(leftY, rightY)
        rule(from: NSPoint(x: margin, y: bottom + 10), to: NSPoint(x: rightX, y: bottom + 10), color: palette.accent, width: 2)
        return bottom + 10
    }

    // MARK: - Bill to

    private func drawBillTo(at top: CGFloat) -> CGFloat {
        var y = top
        y += draw("BILL TO", x: margin, y: y, width: 300, font: .boldSystemFont(ofSize: 8), color: palette.accent, kern: 1.5)
        y += 4
        y += draw(invoice.profile.name, x: margin, y: y, width: 300, font: .boldSystemFont(ofSize: 12), color: InvoicePalette.ink)
        for line in nonEmptyLines(invoice.profile.billingAddress) {
            y += draw(line, x: margin, y: y, width: 300, font: .systemFont(ofSize: 10), color: InvoicePalette.ink)
        }
        if let vat = invoice.profile.vatNumber, !vat.isEmpty {
            y += draw("VAT \(vat)", x: margin, y: y, width: 300, font: .systemFont(ofSize: 10), color: InvoicePalette.muted)
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
        let hasExpense = invoice.lines.contains { $0.isExpense }
        InvoicePalette.panel.setFill()
        NSRect(x: margin, y: y - 5, width: bounds.width - 2 * margin, height: 19).fill()
        _ = draw("Description", x: descX, y: y, width: hoursX - descX - 8, font: headerFont, color: palette.accent)
        _ = draw(hasExpense ? "Qty" : "Hours", x: hoursX, y: y, width: hoursWidth, font: headerFont, color: palette.accent, alignment: .right)
        _ = draw("Rate", x: rateX, y: y, width: rateWidth, font: headerFont, color: palette.accent, alignment: .right)
        _ = draw("Amount", x: amountX, y: y, width: colWidth, font: headerFont, color: palette.accent, alignment: .right)
        y += 24

        for line in invoice.lines {
            let bodyFont = NSFont.systemFont(ofSize: 10)
            let amount = Formatting.money(cents: line.amountCents, currency: invoice.currency)
            let rowHeight = max(
                measured(line.label, width: hoursX - descX - 8, font: bodyFont),
                measured(amount, width: colWidth, font: bodyFont)
            )
            _ = draw(line.label, x: descX, y: y, width: hoursX - descX - 8, font: bodyFont, color: InvoicePalette.ink)
            let quantity: String
            if let value = line.quantity {
                quantity = line.unit.map { "\(Formatting.quantity(value)) \($0)" } ?? Formatting.quantity(value)
            } else {
                quantity = line.seconds < 0 ? "-" + Formatting.decimalHours(-line.seconds) : Formatting.decimalHours(line.seconds)
            }
            _ = draw(quantity, x: hoursX, y: y, width: hoursWidth, font: bodyFont, color: InvoicePalette.ink, alignment: .right)
            let rateCents = line.unitRateCents ?? line.hourlyRateCents
            if rateCents > 0 {
                _ = draw(Formatting.money(cents: rateCents, currency: invoice.currency), x: rateX, y: y, width: rateWidth, font: bodyFont, color: InvoicePalette.ink, alignment: .right)
            }
            _ = draw(amount, x: amountX, y: y, width: colWidth, font: bodyFont, color: InvoicePalette.ink, alignment: .right)
            y += rowHeight + 6
        }

        rule(from: NSPoint(x: margin, y: y), to: NSPoint(x: bounds.width - margin, y: y), color: InvoicePalette.hairline, width: 1)
        return y + 6
    }

    // MARK: - Totals

    private func drawTotals(at top: CGFloat) -> CGFloat {
        var y = top
        let labelX: CGFloat = 305
        let labelWidth: CGFloat = 130
        let rightX = bounds.width - margin

        func row(_ label: String, _ value: String, font: NSFont, color: NSColor) -> CGFloat {
            let height = max(measured(label, width: labelWidth, font: font), measured(value, width: colWidth, font: font))
            _ = draw(label, x: labelX, y: y, width: labelWidth, font: font, color: color, alignment: .right)
            _ = draw(value, x: amountX, y: y, width: colWidth, font: font, color: color, alignment: .right)
            return height
        }

        rule(from: NSPoint(x: labelX, y: y - 8), to: NSPoint(x: rightX, y: y - 8), color: InvoicePalette.hairline, width: 1)
        y += row("Subtotal", Formatting.money(cents: invoice.subtotalCents, currency: invoice.currency), font: .systemFont(ofSize: 10), color: InvoicePalette.muted) + 6
        y += row("VAT \(invoice.vatRatePercent)%", Formatting.money(cents: invoice.vatCents, currency: invoice.currency), font: .systemFont(ofSize: 10), color: InvoicePalette.muted) + 6

        rule(from: NSPoint(x: labelX, y: y), to: NSPoint(x: rightX, y: y), color: palette.accent, width: 2)
        y += 6
        y += row("Total", Formatting.money(cents: invoice.totalCents, currency: invoice.currency), font: .boldSystemFont(ofSize: 13), color: palette.accent) + 4
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
            y += draw(line, x: margin, y: y, width: bounds.width - 2 * margin, font: .systemFont(ofSize: 9), color: InvoicePalette.muted)
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
        color: NSColor = InvoicePalette.ink,
        alignment: NSTextAlignment = .left,
        kern: CGFloat = 0
    ) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        if kern != 0 { attributes[.kern] = kern }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let height = measured(text, width: width, font: font)
        attributed.draw(with: NSRect(x: x, y: y, width: width, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return height
    }

    private func rule(from start: NSPoint, to end: NSPoint, color: NSColor, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        color.setStroke()
        path.lineWidth = width
        path.stroke()
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
