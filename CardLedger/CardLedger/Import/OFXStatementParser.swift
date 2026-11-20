import Foundation
import CryptoKit

enum OFXStatementError: Error, LocalizedError, Equatable {
    case unreadable
    case tooLarge
    case unsupportedStatement
    case multipleAccounts
    case unsupportedCurrency
    case noUsableTransactions

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file isn't a readable OFX or QFX statement."
        case .tooLarge: "This statement is too large. Export a shorter date range and try again."
        case .unsupportedStatement: "Export a credit card statement for one card account in OFX or QFX format."
        case .multipleAccounts: "This file contains multiple card statements. Export each card separately to import it."
        case .unsupportedCurrency: "The statement must identify USD or CAD as its currency."
        case .noUsableTransactions: "No transactions had an unambiguous date, amount, description and transaction ID."
        }
    }
}

/// OFX and QFX use the same statement format. Only the credit card response is imported.
enum OFXStatementParser {
    private static let legacyFields: Set<String> = ["NAME", "MEMO", "DTUSER", "DTPOSTED", "TRNAMT", "FITID", "TRNTYPE"]
    private static let legacyElement = try! NSRegularExpression(pattern: #"<([A-Za-z][A-Za-z0-9_.-]*)>([^<]*)"#)
    private static let rootTag = #"<OFX\s*>"#

    static func parse(data: Data) throws -> ParsedPDFStatement {
        guard data.count <= 16 * 1024 * 1024 else { throw OFXStatementError.tooLarge }
        let text = try decode(data)
        guard let start = text.range(of: rootTag, options: [.regularExpression, .caseInsensitive]),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else { throw OFXStatementError.unreadable }

        let header = text[..<start.lowerBound].uppercased()
        let body = String(text[start.lowerBound...])
        let isLegacy = header.contains("OFXHEADER:100") || header.contains("DATA:OFXSGML")
        let xml = XMLParser(data: Data((isLegacy ? closeLegacyFields(in: body) : body).utf8))
        let document = Document()
        xml.delegate = document
        xml.shouldResolveExternalEntities = false
        guard xml.parse(), let root = document.root, root.name == "OFX" else { throw OFXStatementError.unreadable }

        let responses = root.elements("CREDITCARDMSGSRSV1").flatMap { $0.elements("CCSTMTTRNRS") }
        let statements = responses.flatMap { $0.elements("CCSTMTRS") }
        guard statements.count <= 1 else { throw OFXStatementError.multipleAccounts }
        guard let statement = statements.first, responses.count == 1,
              responses[0].elements("STATUS").allSatisfy({ $0.value("CODE") == "0" }),
              let account = statement.only("CCACCTFROM")?.value("ACCTID"),
              let list = statement.only("BANKTRANLIST") else { throw OFXStatementError.unsupportedStatement }
        guard let currency = statement.value("CURDEF").flatMap({ CurrencyCode(rawValue: $0.uppercased()) }) else {
            throw OFXStatementError.unsupportedCurrency
        }

        let institution = root.only("SIGNONMSGSRSV1")?.only("SONRS")?.only("FI")
        let issuer = institution?.value("ORG")
        let institutionID = institution?.value("FID") ?? issuer ?? ""
        let accountKey = digest("\(currency.rawValue):\(institutionID.utf8.count):\(institutionID)\(account)")
        let rows = list.elements("STMTTRN")
        let referenceCounts = Dictionary(grouping: rows.compactMap { $0.value("FITID") }, by: { $0 }).mapValues(\.count)
        let transactions = rows.enumerated().compactMap { index, row -> ParsedPDFTransaction? in
            guard let reference = row.value("FITID"), referenceCounts[reference] == 1 else { return nil }
            return transaction(row, index: index, reference: reference, accountKey: accountKey, currency: currency)
        }.sorted { $0.posted < $1.posted }
        guard let first = transactions.first, let last = transactions.last else { throw OFXStatementError.noUsableTransactions }

        let skipped = rows.count - transactions.count
        let suffix = account.suffix(4)
        let mask = suffix.utf8.count == 4 && suffix.utf8.allSatisfy { (48...57).contains($0) } ? String(suffix) : nil
        return ParsedPDFStatement(
            detectedIssuer: issuer,
            detectedProductID: nil,
            accountMask: mask,
            currency: currency,
            statementPeriodStart: first.posted,
            statementPeriodEnd: last.posted,
            statementClosingDate: nil,
            paymentDueDate: nil,
            transactions: transactions,
            warnings: skipped == 0 ? [] : ["Skipped \(skipped) transaction rows with missing, ambiguous or unsupported fields."],
            ofxAccountKey: accountKey
        )
    }

    private static func transaction(_ row: Element, index: Int, reference: String, accountKey: String,
                                    currency: CurrencyCode) -> ParsedPDFTransaction? {
        // Corrections change earlier ledger rows, and CURRENCY can change the units of TRNAMT.
        guard row.elements("CORRECTFITID").isEmpty, row.elements("CORRECTACTION").isEmpty,
              row.elements("CURRENCY").isEmpty,
              let posted = row.value("DTPOSTED").flatMap(parseDay),
              let amount = row.value("TRNAMT").flatMap(parseAmount), amount != 0,
              row.elements("NAME").count <= 1, row.elements("MEMO").count <= 1, row.elements("TRNTYPE").count <= 1,
              let description = row.value("NAME") ?? row.value("MEMO") else { return nil }

        // OFX debits are negative. The ledger records charges as positive and payments/refunds as negative.
        let minor = -amount
        let type = row.value("TRNTYPE")?.uppercased()
        guard !(type == "DEBIT" && minor < 0), !(type == "CREDIT" && minor > 0) else { return nil }
        let classification = PDFStatementParser.classifyRow(description: description, amountMinor: minor)
        let kind: TransactionKind = switch (type, minor > 0) {
        case ("PAYMENT", false): .payment
        case ("INT", true), ("FEE", true), ("SRVCHG", true): .fee
        default: classification.kind
        }
        // FITID is unique within an account and can contain private data. Store only its scoped digest.
        return ParsedPDFTransaction(
            id: "ofx-preview-\(index)", posted: posted, authorized: row.value("DTUSER").flatMap(parseDay),
            merchant: classification.merchant, originalDescription: description, amount: Money(minor, currency),
            category: classification.category, kind: kind, rawLine: description, page: 0,
            provenance: .ofx, sourceKey: "\(accountKey):\(digest(reference))"
        )
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func parseDay(_ text: String) -> Date? {
        let pattern = #"\A[0-9]{8}(?:(?:[01][0-9]|2[0-3])[0-5][0-9](?:[0-5][0-9]|60)(?:\.[0-9]{1,3})?(?: *\[[+-]?[0-9]{1,2}(?:\.[0-9]+)?(?::[A-Za-z0-9_+-]+)?\])?)?\z"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        // Preserve the issuer's printed calendar day instead of converting the timestamp to UTC.
        let date = text.prefix(8)
        let key = "\(date.prefix(4))-\(date.dropFirst(4).prefix(2))-\(date.suffix(2))"
        guard let day = Day.parse(key), Day.key(day) == key else { return nil }
        return day
    }

    private static func parseAmount(_ text: String) -> Int? {
        // OFX allows a decimal point or comma. A separator never denotes thousands.
        let pattern = #"\A[+-]?(?:[0-9]+(?:[.,](?:[0-9]{1,2}0*)?)?|[.,][0-9]{1,2}0*)\z"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let digits = text.hasPrefix("-") || text.hasPrefix("+") ? text.dropFirst() : text[...]
        let parts = digits.split(omittingEmptySubsequences: false) { $0 == "." || $0 == "," }
        guard let whole = parts[0].isEmpty ? 0 : Int(parts[0]) else { return nil }
        let fraction = parts.count == 2 ? Int((String(parts[1]) + "00").prefix(2)) ?? 0 : 0
        guard whole <= (Int.max - fraction) / 100 else { return nil }
        let minor = whole * 100 + fraction
        return text.hasPrefix("-") ? -minor : minor
    }

    private static func decode(_ data: Data) throws -> String {
        let prefix = String(decoding: data.prefix(512), as: UTF8.self).uppercased()
        let header = prefix[..<(prefix.range(of: rootTag, options: .regularExpression)?.lowerBound ?? prefix.endIndex)]
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else if header.range(of: #"CHARSET:\s*1252\b|ENCODING\s*=\s*['\"]WINDOWS-1252['\"]"#, options: .regularExpression) != nil {
            text = String(data: data, encoding: .windowsCP1252)
        } else if header.range(of: #"CHARSET:\s*8859-1\b|ENCODING\s*=\s*['\"]ISO-8859-1['\"]"#, options: .regularExpression) != nil {
            text = String(data: data, encoding: .isoLatin1)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard let text else { throw OFXStatementError.unreadable }
        return text
    }

    private static func closeLegacyFields(in body: String) -> String {
        // OFX 1.x leaves scalar end tags out; aggregates still have explicit closing tags.
        let matches = legacyElement.matches(in: body, range: NSRange(body.startIndex..., in: body))
        var xml = ""
        var cursor = body.startIndex
        for match in matches {
            guard let tagRange = Range(match.range(at: 1), in: body),
                  let valueRange = Range(match.range(at: 2), in: body) else { continue }
            let name = body[tagRange]
            let value = body[valueRange]
            let close = "</\(name)>"
            guard legacyFields.contains(name.uppercased()) || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            xml += body[cursor..<valueRange.lowerBound]
            xml += value.replacingOccurrences(of: #"&(?!amp;|lt;|gt;|apos;|quot;|#[0-9]+;|#x[0-9A-Fa-f]+;)"#,
                                               with: "&amp;", options: .regularExpression)
            if !body[valueRange.upperBound...].hasPrefix(close) { xml += close }
            cursor = valueRange.upperBound
        }
        xml += body[cursor...]
        return xml
    }

    private struct Element {
        let name: String
        var text = ""
        var children: [Element] = []

        func elements(_ name: String) -> [Element] { children.filter { $0.name == name } }

        func only(_ name: String) -> Element? {
            let matches = elements(name)
            return matches.count == 1 ? matches[0] : nil
        }

        func value(_ name: String) -> String? {
            guard let item = only(name), item.children.isEmpty else { return nil }
            let value = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private final class Document: NSObject, XMLParserDelegate {
        var root: Element?
        private var stack: [Element] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            guard stack.count < 32 else { parser.abortParsing(); return }
            stack.append(Element(name: elementName.uppercased()))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !stack.isEmpty { stack[stack.count - 1].text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let text = String(data: CDATABlock, encoding: .utf8) else { parser.abortParsing(); return }
            self.parser(parser, foundCharacters: text)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let element = stack.popLast() else { return }
            if stack.isEmpty { root = element }
            else { stack[stack.count - 1].children.append(element) }
        }
    }
}
