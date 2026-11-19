import Foundation

struct PDFImportResult: Equatable {
    let cardID: String
    var inserted: Int = 0
    var skippedDuplicates: Int = 0
}

extension LedgerRepository {
    /// Creates a live card for statement import and returns its generated local ID.
    @discardableResult
    func createCardForImport(
        nickname: String,
        productID: String,
        mask: String?,
        openedOn: Date,
        renewal: Date? = nil
    ) throws -> String {
        try db.transaction {
            try insertCardInOpenTransaction(nickname: nickname, productID: productID, mask: mask, openedOn: openedOn, renewal: renewal)
        }
    }

    /// Atomically creates a new live card and imports the parsed PDF transactions into it.
    @discardableResult
    func createCardAndImportPDF(
        nickname: String,
        productID: String,
        mask: String?,
        openedOn: Date,
        renewal: Date? = nil,
        transactions items: [ParsedPDFTransaction],
        skipMatchingExisting: Bool = true
    ) throws -> PDFImportResult {
        try db.transaction {
            let cardID = try insertCardInOpenTransaction(
                nickname: nickname,
                productID: productID,
                mask: mask,
                openedOn: openedOn,
                renewal: renewal
            )
            return try insertPDFTransactionsInOpenTransaction(items, cardID: cardID, skipMatchingExisting: skipMatchingExisting)
        }
    }

    /// Returns stored PDF `source_id` keys for a card so the import preview can flag exact re-imports.
    func existingPDFSourceIDs(cardID: String) throws -> Set<String> {
        let rows = try db.query("SELECT source_id FROM txn WHERE card_id = ? AND source_id LIKE 'pdf:%'", [cardID.sql])
        return Set(rows.compactMap { $0["source_id"]?.string })
    }

    /// Imports parsed PDF statement transactions into the encrypted local ledger in one SQLite transaction.
    ///
    /// Occurrence indexes are computed over all `items` in order so toggling `include` on a preview row never
    /// shifts another identical same-day transaction's deterministic `source_id`. Unchecked items (`!item.include`)
    /// are ignored and not counted in `inserted` or `skippedDuplicates`.
    @discardableResult
    func importPDFTransactions(
        _ items: [ParsedPDFTransaction],
        cardID: String,
        skipMatchingExisting: Bool = true
    ) throws -> PDFImportResult {
        try db.transaction {
            try insertPDFTransactionsInOpenTransaction(items, cardID: cardID, skipMatchingExisting: skipMatchingExisting)
        }
    }

    private func insertCardInOpenTransaction(
        nickname: String,
        productID: String,
        mask: String?,
        openedOn: Date,
        renewal: Date?
    ) throws -> String {
        let cardID = UUID().uuidString
        let iso = ISO8601DateFormatter()
        let sql = """
            INSERT INTO card(id, nickname, product_id, mask, opened_on, renewal_date, renewal_precision, renewal_source, created_at, opened_status)
            VALUES(?,?,?,?,?,?,?,?,?,'confirmed')
            """
        try db.run(sql, [
            cardID.sql,
            nickname.sql,
            productID.sql,
            mask.sql,
            Day.key(openedOn).sql,
            renewal.map { Day.key($0) }.sql,
            (renewal == nil ? nil : "day").sql,
            (renewal == nil ? nil : RenewalDate.Source.owner.rawValue).sql,
            iso.string(from: Date()).sql,
        ])
        return cardID
    }

    private func insertPDFTransactionsInOpenTransaction(
        _ items: [ParsedPDFTransaction],
        cardID: String,
        skipMatchingExisting: Bool
    ) throws -> PDFImportResult {
        var result = PDFImportResult(cardID: cardID)

        var existingSourceIDs = Set(
            try db.query("SELECT source_id FROM txn WHERE card_id = ?", [cardID.sql])
                .compactMap { $0["source_id"]?.string }
        )

        let existingTransactions: [Transaction] = skipMatchingExisting ? try loadTransactions(forCardID: cardID) : []
        var consumedExistingIDs: Set<String> = []
        var occurrenceCounts: [String: Int] = [:]

        for item in items {
            let occKey = PDFStatementParser.occurrenceKey(for: item)
            let occIndex = occurrenceCounts[occKey, default: 0]
            occurrenceCounts[occKey] = occIndex + 1

            guard item.include else { continue }

            let sourceID = PDFStatementParser.sourceID(cardID: cardID, transaction: item, occurrenceIndex: occIndex)
            if existingSourceIDs.contains(sourceID) {
                result.skippedDuplicates += 1
                continue
            }

            if skipMatchingExisting,
               let match = existingTransactions.first(where: {
                   !consumedExistingIDs.contains($0.id) && PDFStatementParser.matchesExisting(item, existing: $0)
               }) {
                consumedExistingIDs.insert(match.id)
                result.skippedDuplicates += 1
                continue
            }

            let localID = UUID().uuidString
            try db.run("""
                INSERT INTO txn(id, card_id, provenance, source_id, amount_minor, currency, posted, authorized,
                  merchant, original_description, category, kind, pending, mcc)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0,NULL)
                """, [
                    localID.sql,
                    cardID.sql,
                    Provenance.pdf.rawValue.sql,
                    sourceID.sql,
                    item.amount.minor.sql,
                    item.amount.currency.rawValue.sql,
                    Day.key(item.posted).sql,
                    item.authorized.map { Day.key($0) }.sql,
                    item.merchant.sql,
                    item.originalDescription.sql,
                    item.category.rawValue.sql,
                    item.kind.rawValue.sql,
                ])
            existingSourceIDs.insert(sourceID)
            result.inserted += 1
        }

        return result
    }

    private func loadTransactions(forCardID cardID: String) throws -> [Transaction] {
        try db.query("SELECT * FROM txn WHERE card_id = ?", [cardID.sql]).compactMap { r in
            guard let currency = r["currency"]?.string.flatMap(CurrencyCode.init(rawValue:)),
                  let posted = Day.parse(r["posted"]?.string) else { return nil }
            return Transaction(
                id: r["id"]!.string!,
                cardID: r["card_id"]!.string!,
                amount: Money(r["amount_minor"]!.int!, currency),
                posted: posted,
                authorized: Day.parse(r["authorized"]?.string),
                merchant: r["merchant"]!.string!,
                originalDescription: r["original_description"]!.string!,
                category: RewardCategory(rawValue: r["category"]!.string!) ?? .other,
                kind: TransactionKind(rawValue: r["kind"]!.string!) ?? .purchase,
                pending: r["pending"]!.bool,
                provenance: Provenance(rawValue: r["provenance"]!.string!) ?? .plaid
            )
        }
    }
}
