import Foundation

enum PDFImportStoreError: Error, LocalizedError {
    case storageUnavailable
    case sampleModeRequiresNewCard

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            "Encrypted local storage is unavailable on this iPhone."
        case .sampleModeRequiresNewCard:
            "Create a new card to start your live ledger before importing statements into it."
        }
    }
}

@MainActor
extension Store {
    /// Predicts which parsed preview rows would be skipped as duplicates on `cardID`,
    /// mirroring `LedgerRepository.importPDFTransactions` occurrence-index and cross-source logic.
    func duplicateIDs(
        for parsed: [ParsedPDFTransaction],
        onCardID cardID: String?,
        skipCrossSource: Bool = true
    ) -> Set<String> {
        guard mode == .live, let cardID else { return [] }
        let existingSourceIDs = (try? repo?.existingPDFSourceIDs(cardID: cardID)) ?? []
        let existingTransactions = skipCrossSource ? effectiveTransactions.filter { $0.cardID == cardID } : []

        var duplicates: Set<String> = []
        var consumedExistingIDs: Set<String> = []
        var occurrenceCounts: [String: Int] = [:]

        for item in parsed {
            let occKey = PDFStatementParser.occurrenceKey(for: item)
            let occIndex = occurrenceCounts[occKey, default: 0]
            occurrenceCounts[occKey] = occIndex + 1

            let sourceID = PDFStatementParser.sourceID(cardID: cardID, transaction: item, occurrenceIndex: occIndex)
            if existingSourceIDs.contains(sourceID) {
                duplicates.insert(item.id)
                continue
            }

            if skipCrossSource,
               let match = existingTransactions.first(where: {
                   !consumedExistingIDs.contains($0.id) && PDFStatementParser.matchesExisting(item, existing: $0)
               }) {
                consumedExistingIDs.insert(match.id)
                duplicates.insert(item.id)
            }
        }
        return duplicates
    }

    /// Suggests the best matching live card for a parsed PDF statement based on last-4 mask, product, and issuer.
    func suggestedCardID(for statement: ParsedPDFStatement) -> String? {
        guard mode == .live, !cards.isEmpty else { return nil }

        if let mask = statement.accountMask {
            let exactMarket = cards.filter { $0.mask == mask && Catalog.product($0.productID).market == statement.currency }
            if exactMarket.count == 1 { return exactMarket[0].id }
            let anyMask = cards.filter { $0.mask == mask }
            if anyMask.count == 1 { return anyMask[0].id }
        }

        if let productID = statement.detectedProductID {
            let matchingProduct = cards.filter { $0.productID == productID }
            if matchingProduct.count == 1 { return matchingProduct[0].id }
        }

        if let issuer = statement.detectedIssuer {
            let matchingIssuer = cards.filter {
                let p = Catalog.product($0.productID)
                return p.market == statement.currency && p.issuer.localizedCaseInsensitiveContains(issuer)
            }
            if matchingIssuer.count == 1 { return matchingIssuer[0].id }
        }

        return nil
    }

    @discardableResult
    func importPDFStatement(
        transactions: [ParsedPDFTransaction],
        intoExistingCardID cardID: String,
        skipCrossSourceDuplicates: Bool = true
    ) throws -> PDFImportResult {
        guard let repo else { throw PDFImportStoreError.storageUnavailable }
        guard mode == .live else { throw PDFImportStoreError.sampleModeRequiresNewCard }
        let result = try repo.importPDFTransactions(
            transactions,
            cardID: cardID,
            skipMatchingExisting: skipCrossSourceDuplicates
        )
        reload()
        return result
    }

    @discardableResult
    func importPDFStatementIntoNewCard(
        transactions: [ParsedPDFTransaction],
        nickname: String,
        productID: String,
        mask: String?,
        openedOn: Date,
        renewal: Date? = nil,
        skipCrossSourceDuplicates: Bool = true
    ) throws -> PDFImportResult {
        guard let repo else { throw PDFImportStoreError.storageUnavailable }
        let result = try repo.createCardAndImportPDF(
            nickname: nickname,
            productID: productID,
            mask: mask,
            openedOn: openedOn,
            renewal: renewal,
            transactions: transactions,
            skipMatchingExisting: skipCrossSourceDuplicates
        )
        reload()
        return result
    }
}
