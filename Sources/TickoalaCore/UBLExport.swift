import Foundation

/// Turns an `Invoice` into a UBL 2.1 document, the XML that Peppol and every
/// Dutch bookkeeping package (Moneybird, e-Boekhouden, Exact, …) can import. It
/// is pure string work: nothing is sent anywhere, the caller writes the file.
///
/// The output follows Peppol BIS Billing 3 (the EN 16931 ruleset) closely enough
/// to import cleanly. It is not validated: a client whose data is incomplete may
/// produce a document a strict receiver rejects, which is why the app still
/// offers the PDF alongside it.
public enum UBLExport {
    /// The UBL 2.1 document for one invoice.
    public static func document(for invoice: Invoice, calendar: Calendar = Formatting.calendar) -> String {
        let currency = invoice.currency.rawValue
        let supplier = address(invoice.sender.senderAddress)
        let customer = address(invoice.profile.billingAddress ?? "")
        let taxCategory = taxCategoryID(for: invoice)
        let exemption = invoice.profile.vatRatePercent == 0 && !taxCategoryIsZeroRated(taxCategory)

        // A credit note is its own UBL document (`CreditNote`, type 381). EN 16931
        // keeps the line amounts positive there; the document type carries the
        // direction, so the figures are taken as absolute values.
        let isCredit = invoice.isCredit
        let root = isCredit ? "CreditNote" : "Invoice"
        let rootNamespace = isCredit
            ? "urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2"
            : "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
        let typeCode = isCredit ? "381" : "380"
        let lineTag = isCredit ? "CreditNoteLine" : "InvoiceLine"
        let quantityTag = isCredit ? "CreditedQuantity" : "InvoicedQuantity"
        // The figures live in the Invoice as negatives; UBL wants them positive.
        func amt(_ cents: Int) -> String { Formatting.decimalAmount(cents: isCredit ? abs(cents) : cents) }

        var lines = ""
        lines += "  <cac:AccountingSupplierParty>\n    <cac:Party>\n"
        lines += "      <cac:PartyName>\n        <cbc:Name>\(escaped(invoice.sender.senderName))</cbc:Name>\n      </cac:PartyName>\n"
        lines += postalAddress(supplier, tag: "PostalAddress")
        lines += partyTaxScheme(exemption: false, companyID: invoice.sender.senderVatNumber)
        lines += "      <cac:PartyLegalEntity>\n        <cbc:RegistrationName>\(escaped(invoice.sender.senderName))</cbc:RegistrationName>\n"
        if !invoice.sender.senderKvk.isEmpty {
            lines += "        <cbc:CompanyID>\(escaped(invoice.sender.senderKvk))</cbc:CompanyID>\n"
        }
        lines += "      </cac:PartyLegalEntity>\n    </cac:Party>\n  </cac:AccountingSupplierParty>\n"

        lines += "  <cac:AccountingCustomerParty>\n    <cac:Party>\n"
        lines += "      <cac:PartyName>\n        <cbc:Name>\(escaped(invoice.profile.name))</cbc:Name>\n      </cac:PartyName>\n"
        lines += postalAddress(customer, tag: "PostalAddress")
        if let vatNumber = invoice.profile.vatNumber, !vatNumber.isEmpty {
            lines += partyTaxScheme(exemption: exemption, companyID: vatNumber)
        }
        lines += "      <cac:PartyLegalEntity>\n        <cbc:RegistrationName>\(escaped(invoice.profile.name))</cbc:RegistrationName>\n      </cac:PartyLegalEntity>\n"
        lines += "    </cac:Party>\n  </cac:AccountingCustomerParty>\n"

        // A credit note is not paid; there is no payment means or due date on it.
        if !isCredit, !invoice.sender.senderIban.isEmpty {
            lines += "  <cac:PaymentMeans>\n    <cbc:PaymentMeansCode>30</cbc:PaymentMeansCode>\n"
            lines += "    <cbc:PaymentID>\(escaped(invoice.number))</cbc:PaymentID>\n"
            lines += "    <cac:PayeeFinancialAccount>\n      <cbc:ID>\(escaped(invoice.sender.senderIban))</cbc:ID>\n    </cac:PayeeFinancialAccount>\n"
            lines += "  </cac:PaymentMeans>\n"
        }

        lines += "  <cac:TaxTotal>\n    <cbc:TaxAmount currencyID=\"\(currency)\">\(amt(invoice.vatCents))</cbc:TaxAmount>\n"
        lines += "    <cac:TaxSubtotal>\n"
        lines += "      <cbc:TaxableAmount currencyID=\"\(currency)\">\(amt(invoice.subtotalCents))</cbc:TaxableAmount>\n"
        lines += "      <cbc:TaxAmount currencyID=\"\(currency)\">\(amt(invoice.vatCents))</cbc:TaxAmount>\n"
        lines += "      <cac:TaxCategory>\n        <cbc:ID>\(taxCategory)</cbc:ID>\n"
        lines += "        <cbc:Percent>\(invoice.profile.vatRatePercent)</cbc:Percent>\n"
        if exemption {
            lines += "        <cbc:TaxExemptionReason>Reverse charge</cbc:TaxExemptionReason>\n"
        }
        lines += "        <cac:TaxScheme>\n          <cbc:ID>VAT</cbc:ID>\n        </cac:TaxScheme>\n"
        lines += "      </cac:TaxCategory>\n    </cac:TaxSubtotal>\n  </cac:TaxTotal>\n"

        lines += "  <cac:LegalMonetaryTotal>\n"
        lines += "    <cbc:LineExtensionAmount currencyID=\"\(currency)\">\(amt(invoice.subtotalCents))</cbc:LineExtensionAmount>\n"
        lines += "    <cbc:TaxExclusiveAmount currencyID=\"\(currency)\">\(amt(invoice.subtotalCents))</cbc:TaxExclusiveAmount>\n"
        lines += "    <cbc:TaxInclusiveAmount currencyID=\"\(currency)\">\(amt(invoice.totalCents))</cbc:TaxInclusiveAmount>\n"
        lines += "    <cbc:PayableAmount currencyID=\"\(currency)\">\(amt(invoice.totalCents))</cbc:PayableAmount>\n"
        lines += "  </cac:LegalMonetaryTotal>\n"

        var number = 0
        // Credit lines carry negative seconds in the model but positive UBL
        // quantities, so the deduction filter does not apply to them.
        for line in invoice.lines where isCredit || !line.isDeduction {
            number += 1
            lines += invoiceLine(
                number: number, line: line, currency: currency,
                tag: lineTag, quantityTag: quantityTag, positive: isCredit
            )
        }

        let documentType = isCredit ? "<cbc:CreditNoteTypeCode>" : "<cbc:InvoiceTypeCode>"
        let documentTypeClose = isCredit ? "</cbc:CreditNoteTypeCode>" : "</cbc:InvoiceTypeCode>"
        // The Belastingdienst asks a document that amends an earlier invoice to
        // name it; EN 16931 carries that in BillingReference.
        let reference: String
        if isCredit, let original = invoice.creditForNumber {
            reference = "  <cac:BillingReference>\n    <cac:InvoiceDocumentReference>\n      <cbc:ID>\(escaped(original))</cbc:ID>\n    </cac:InvoiceDocumentReference>\n  </cac:BillingReference>\n"
        } else {
            reference = ""
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <\(root) xmlns="\(rootNamespace)"
                 xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
                 xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
          <cbc:CustomizationID>urn:cen.eu:en16931:2017</cbc:CustomizationID>
          <cbc:ProfileID>urn:fdc:peppol.eu:2017:poacc:billing:01:1.0</cbc:ProfileID>
          <cbc:ID>\(escaped(invoice.number))</cbc:ID>
        \(reference)  <cbc:IssueDate>\(Formatting.day(invoice.issuedAt))</cbc:IssueDate>
        \(isCredit ? "" : "  <cbc:DueDate>\(Formatting.day(invoice.dueAt))</cbc:DueDate>\n")  \(documentType)\(typeCode)\(documentTypeClose)
          <cbc:DocumentCurrencyCode>\(currency)</cbc:DocumentCurrencyCode>
        \(invoice.poNumber.map { "  <cbc:BuyerReference>\(escaped($0))</cbc:BuyerReference>\n" } ?? "")\(lines)</\(root)>

        """
    }

    /// The document as UTF-8 bytes, ready to write to a `.xml` file.
    public static func data(for invoice: Invoice, calendar: Calendar = Formatting.calendar) -> Data {
        Data(document(for: invoice, calendar: calendar).utf8)
    }

    // MARK: - Building blocks

    private static func invoiceLine(
        number: Int,
        line: InvoiceLine,
        currency: String,
        tag: String,
        quantityTag: String,
        positive: Bool
    ) -> String {
        // Hours lines carry the seconds at the client's rate; expenses and mileage
        // carry their own quantity, unit and rate. A credit's line is stored
        // negative but written positive, as the document type implies the sign.
        let sign: (Double) -> Double = positive ? { abs($0) } : { $0 }
        let quantity: Double
        let unit: String
        let price: Int
        if line.isExpense {
            quantity = sign(line.quantity ?? 1)
            unit = unitCode(line.unit)
            price = line.unitRateCents ?? (line.quantity.map { $0 != 0 ? Int((Double(line.amountCents) / $0).rounded()) : 0 } ?? 0)
        } else {
            quantity = sign(line.seconds / 3600)
            unit = "HUR"
            price = line.hourlyRateCents
        }

        func shown(_ cents: Int) -> String { Formatting.decimalAmount(cents: positive ? abs(cents) : cents) }

        var xml = "  <cac:\(tag)>\n"
        xml += "    <cbc:ID>\(number)</cbc:ID>\n"
        xml += "    <cbc:\(quantityTag) unitCode=\"\(unit)\">\(Formatting.quantity(quantity))</cbc:\(quantityTag)>\n"
        xml += "    <cbc:LineExtensionAmount currencyID=\"\(currency)\">\(shown(line.amountCents))</cbc:LineExtensionAmount>\n"
        xml += "    <cac:Item>\n      <cbc:Name>\(escaped(line.label))</cbc:Name>\n    </cac:Item>\n"
        xml += "    <cac:Price>\n      <cbc:PriceAmount currencyID=\"\(currency)\">\(shown(price))</cbc:PriceAmount>\n    </cac:Price>\n"
        xml += "  </cac:\(tag)>\n"
        return xml
    }

    private static func partyTaxScheme(exemption: Bool, companyID: String) -> String {
        var xml = "      <cac:PartyTaxScheme>\n        <cbc:CompanyID>\(escaped(companyID))</cbc:CompanyID>\n"
        if exemption {
            xml += "        <cbc:TaxExemptionReason>Reverse charge</cbc:TaxExemptionReason>\n"
        }
        xml += "        <cac:TaxScheme>\n          <cbc:ID>VAT</cbc:ID>\n        </cac:TaxScheme>\n"
        xml += "      </cac:PartyTaxScheme>\n"
        return xml
    }

    private static func postalAddress(_ parts: AddressParts, tag: String) -> String {
        var xml = "      <cac:\(tag)>\n"
        for street in parts.streetLines where !street.isEmpty {
            xml += "        <cbc:StreetName>\(escaped(street))</cbc:StreetName>\n"
        }
        if let postal = parts.postalCode, !postal.isEmpty {
            xml += "        <cbc:PostalZone>\(escaped(postal))</cbc:PostalZone>\n"
        }
        if !parts.city.isEmpty {
            xml += "        <cbc:CityName>\(escaped(parts.city))</cbc:CityName>\n"
        }
        xml += "        <cac:Country>\n          <cbc:IdentificationCode>\(parts.countryCode)</cbc:IdentificationCode>\n        </cac:Country>\n"
        xml += "      </cac:\(tag)>\n"
        return xml
    }

    // MARK: - Address heuristics

    public struct AddressParts {
        public var streetLines: [String]
        public var postalCode: String?
        public var city: String
        public var countryCode: String
    }

    /// Peppol wants a structured address, but Tickoala stores one free-form block.
    /// This splits the common Dutch shape (`Street 1`, `1234 AB City`, `Netherlands`)
    /// as well as it can; anything it cannot place is left as a street line. A
    /// missing country falls back to NL, which is where most users are.
    // ponytail: heuristic address parsing; add structured fields if receivers reject it.
    public static func address(_ text: String) -> AddressParts {
        var lines = text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var code = "NL"
        if let last = lines.last {
            if let found = countryCode(forName: last) {
                code = found
                lines.removeLast()
            }
        }

        // The Dutch shape first, then a looser "digits then city" for neighbours.
        let patterns = [
            #"^(\d{4}\s?[A-Za-z]{2})\s+(.+)$"#,
            #"^(\d{4,6})\s+(.+)$"#,
        ]
        var postalCode: String?
        var city = ""
        for pattern in patterns {
            guard let index = lines.firstIndex(where: {
                $0.range(of: pattern, options: .regularExpression) != nil
            }) else { continue }
            let line = lines.remove(at: index)
            if let match = line.range(of: pattern, options: .regularExpression) {
                let matched = String(line[match])
                let groups = matched.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                if groups.count >= 2 {
                    postalCode = groups.count >= 3 ? "\(groups[0]) \(groups[1])" : String(groups[0])
                    city = String(groups[groups.count - 1])
                }
            }
            break
        }
        if city.isEmpty, let last = lines.last, !isStreetLike(last) {
            city = lines.removeLast()
        }

        return AddressParts(streetLines: lines, postalCode: postalCode, city: city, countryCode: code)
    }

    private static func isStreetLike(_ line: String) -> Bool {
        line.range(of: #"\d"#, options: .regularExpression) != nil
    }

    private static func countryCode(forName line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 2, trimmed.range(of: #"^[A-Za-z]{2}$"#, options: .regularExpression) != nil {
            return trimmed.uppercased()
        }
        let names = [
            "netherlands": "NL", "nederland": "NL", "the netherlands": "NL",
            "belgium": "BE", "belgië": "BE", "belgie": "BE",
            "germany": "DE", "duitsland": "DE",
            "france": "FR", "frankrijk": "FR",
            "united kingdom": "GB", "great britain": "GB",
            "spain": "ES", "spanje": "ES",
            "italy": "IT", "italië": "IT", "italie": "IT",
            "united states": "US", "usa": "US",
        ]
        return names[trimmed.lowercased()]
    }

    // MARK: - VAT

    /// Peppol's tax category: standard rate, zero-rated, or reverse charge (AE).
    /// The app only knows a percentage, so 0% with a client VAT number is treated
    /// as reverse charge, and 0% without one as zero-rated.
    private static func taxCategoryID(for invoice: Invoice) -> String {
        if invoice.profile.vatRatePercent > 0 { return "S" }
        let vatNumber = invoice.profile.vatNumber?.trimmingCharacters(in: .whitespaces) ?? ""
        return vatNumber.isEmpty ? "Z" : "AE"
    }

    private static func taxCategoryIsZeroRated(_ id: String) -> Bool { id == "Z" }

    // MARK: - Primitives

    private static func unitCode(_ unit: String?) -> String {
        switch unit {
        case "km": return "KMT"
        case nil: return "C62"
        default: return "C62"
        }
    }

    /// Minimal XML escaping: the five characters that would otherwise break the
    /// document. Control characters are dropped rather than encoded.
    public static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20, character != "\n", character != "\t" {
                    continue
                }
                result.append(character)
            }
        }
        return result
    }
}
