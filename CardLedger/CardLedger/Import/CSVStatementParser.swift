import Foundation

enum CSVStatementError: Error, LocalizedError, Equatable {
    case unreadable
    case unsupportedFormat
    case noRows

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file couldn't be read as text."
        case .unsupportedFormat: "This CSV layout isn't supported yet. Card Ledger currently reads the American Express Canada activity export."
        case .noRows: "The CSV has no transaction rows."
        }
    }
}

/// On-device parser for card activity CSV exports. Produces the same reviewable statement as PDF import.
///
/// Supported: American Express Canada "activity.csv" (Date, Date Processed, Description, Card Member, Account #,
/// Amount, …, Additional Information, …, Reference). Amounts are positive for charges. Card-linked offer credits
/// carry their label in Additional Information ("ShopSmallOffer").
enum CSVStatementParser {
    static func parse(data: Data) throws -> ParsedPDFStatement {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CSVStatementError.unreadable
        }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> ParsedPDFStatement {
        let records = parseRecords(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard let header = records.first else { throw CSVStatementError.noRows }
        let columns = Dictionary(header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces).lowercased(), $0) },
                                 uniquingKeysWith: { a, _ in a })
        guard let date = columns["date"], let processed = columns["date processed"], let desc = columns["description"],
              let amount = columns["amount"], let reference = columns["reference"] else {
            throw CSVStatementError.unsupportedFormat
        }
        let info = columns["additional information"]
        let account = columns["account #"]
        let dueDateCol = ["payment due date", "due date", "bill due date", "next payment due date", "payment due"]
            .compactMap { columns[$0] }.first

        var transactions: [ParsedPDFTransaction] = []
        var accounts: [String: Int] = [:]
        var latestDueDate: Date?
        var skipped = 0
        for (index, record) in records.dropFirst().enumerated() {
            func field(_ i: Int?) -> String {
                guard let i, i < record.count else { return "" }
                return record[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !record.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            if let dueCol = dueDateCol, let parsedDue = parseFlexibleDate(field(dueCol)) {
                latestDueDate = max(latestDueDate ?? parsedDue, parsedDue)
            }
            guard let posted = parseDate(field(processed)) ?? parseDate(field(date)),
                  let minor = parseAmount(field(amount)), minor != 0 else {
                skipped += 1
                continue
            }
            let description = field(desc).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let row = PDFStatementParser.classifyRow(description: description, amountMinor: minor)
            let tag = field(info)
            let ref = field(reference).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let digits = field(account).filter(\.isNumber)
            if !digits.isEmpty { accounts[digits, default: 0] += 1 }

            var t = ParsedPDFTransaction(
                id: "csv-preview-\(index)",
                posted: posted,
                authorized: parseDate(field(date)),
                merchant: row.merchant,
                originalDescription: description,
                amount: Money(minor, .cad),
                category: row.category,
                kind: row.kind,
                rawLine: record.joined(separator: ","),
                page: 0,
                provenance: .csv,
                sourceKey: ref.isEmpty ? nil : ref,
                offerTag: PDFStatementParser.isOfferTag(tag) ? tag : nil
            )
            if t.offerTag == nil, minor < 0, tag.range(of: #"(?:Offer|OFFER)$"#, options: .regularExpression) != nil {
                t.offerTag = tag
            }
            transactions.append(t)
        }
        guard !transactions.isEmpty else { throw CSVStatementError.noRows }
        PDFStatementParser.markOfferCredits(&transactions)
        transactions.sort { $0.posted < $1.posted }

        var warnings: [String] = []
        let ranked = accounts.sorted { $0.value > $1.value }
        if ranked.count > 1 {
            let others = ranked.dropFirst().map { "•••• \($0.key)" }.joined(separator: ", ")
            warnings.append("Includes rows from additional cards on this account (\(others)). They import to the same card.")
        }
        if skipped > 0 {
            warnings.append("\(skipped) row\(skipped == 1 ? "" : "s") without a date or amount were skipped.")
        }
        let dates = transactions.map(\.posted)
        return ParsedPDFStatement(
            detectedIssuer: "American Express",
            detectedProductID: nil,
            accountMask: ranked.first.map { String($0.key.suffix(5)) },
            currency: .cad,
            statementPeriodStart: dates.min(),
            statementPeriodEnd: dates.max(),
            statementClosingDate: nil,
            paymentDueDate: latestDueDate,
            transactions: transactions,
            warnings: warnings
        )
    }

    /// RFC 4180 records: quoted fields may contain commas, doubled quotes and line breaks.
    static func parseRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"": inQuotes = true
            case ",": record.append(field); field = ""
            case "\n", "\r\n", "\r":
                record.append(field); field = ""
                records.append(record); record = []
            default: field.append(c)
            }
        }
        if !field.isEmpty || !record.isEmpty { record.append(field); records.append(record) }
        return records
    }

    private static let months = ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
                                 "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12]

    /// "17 Nov 2026" (Amex Canada export) → calendar day.
    static func parseDate(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 3, let d = Int(parts[0]), let y = Int(parts[2]),
              let m = months[String(parts[1].prefix(3)).uppercased()], (1...31).contains(d), (1990...2100).contains(y) else { return nil }
        let date = Day.make(y, m, d)
        let check = Day.ymd(date)
        return check.y == y && check.m == m && check.d == d ? date : nil
    }

    /// Parses common CSV due-date formats (`YYYY-MM-DD`, `DD MMM YYYY`, `MM/DD/YYYY`, `MMM DD, YYYY`).
    static func parseFlexibleDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let d = parseDate(text) { return d }
        if text.utf8.count >= 10, let d = Day.parse(String(text.prefix(10))), Day.key(d) == String(text.prefix(10)) {
            return d
        }
        let slash = text.split(separator: "/")
        if slash.count == 3, let mo = Int(slash[0]), let day = Int(slash[1]), let rawY = Int(slash[2]),
           (1...12).contains(mo), (1...31).contains(day) {
            let y = rawY < 100 ? 2000 + rawY : rawY
            if (1990...2100).contains(y) {
                let d = Day.make(y, mo, day)
                let check = Day.ymd(d)
                if check.y == y && check.m == mo && check.d == day { return d }
            }
        }
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        let parts = cleaned.split(separator: " ")
        if parts.count == 3, let m = months[String(parts[0].prefix(3)).uppercased()],
           let day = Int(parts[1]), let y = Int(parts[2]), (1...31).contains(day), (1990...2100).contains(y) {
            let d = Day.make(y, m, day)
            let check = Day.ymd(d)
            if check.y == y && check.m == m && check.d == day { return d }
        }
        return nil
    }

    /// "1,234.56", "-5.00", "$7.90" → minor units.
    static func parseAmount(_ text: String) -> Int? {
        var s = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        guard let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let minor = NSDecimalNumber(decimal: d * 100).rounding(accordingToBehavior: nil).intValue
        return negative ? -minor : minor
    }
}
