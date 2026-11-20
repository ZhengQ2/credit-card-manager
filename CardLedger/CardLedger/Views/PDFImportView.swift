import SwiftUI
import UniformTypeIdentifiers

/// Statement file the importer reads.
enum StatementFileFormat: String, CaseIterable, Identifiable {
    case pdf
    case csv
    case ofx

    var id: Self { self }

    var title: String {
        switch self {
        case .pdf: "Import PDF statement"
        case .csv: "Import CSV activity"
        case .ofx: "Import OFX or QFX"
        }
    }

    var icon: String {
        switch self {
        case .pdf: "doc.richtext"
        case .csv: "tablecells"
        case .ofx: "doc.text"
        }
    }

    var contentTypes: [UTType] {
        switch self {
        case .pdf: [.pdf]
        case .csv: [.commaSeparatedText, .plainText]
        case .ofx: ["ofx", "qfx"].compactMap { UTType(filenameExtension: $0) }
        }
    }

    var pickerLabel: String { self == .ofx ? "OFX or QFX" : rawValue.uppercased() }

    func reminderStatementDate(for statement: ParsedPDFStatement) -> Date? {
        // An OFX download's activity range cannot establish a billing cycle's closing date.
        statement.statementClosingDate ?? (self == .ofx ? nil : statement.statementPeriodEnd)
    }
}

/// On-device importer for PDF, CSV, OFX and QFX. Files are parsed locally
/// without sending any file or statement text off the iPhone (design §6).
struct PDFImportView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Optional live card ID when opened from `CardDetailView`.
    var preselectedCardID: String? = nil
    var preselectedProductID: String? = nil
    var format: StatementFileFormat = .pdf
    var onImported: (() -> Void)? = nil

    private var preselectedProduct: CardProduct? { preselectedProductID.flatMap(Catalog.exactProduct) }

    private enum ImportTarget: Hashable {
        case existing(String)
        case newCard
    }

    @State private var pickingFile = false
    @State private var pdfData: Data?
    @State private var fileName: String?
    @State private var needsPassword = false
    @State private var password = ""
    @State private var parseError: String?

    @State private var statement: ParsedPDFStatement?
    @State private var statementCurrency: CurrencyCode = .usd
    @State private var target: ImportTarget = .newCard

    // New-card draft fields (used when `target == .newCard`)
    @State private var newCardMarket: CurrencyCode = .usd
    @State private var newCardProductID: String = "custom-us"
    @State private var newCardNickname: String = ""
    @State private var newCardMask: String = ""
    @State private var newCardOpenedOn: Date = Day.toLocal(Day.addMonths(-12, to: Day.today))

    @State private var skipCrossSourceDuplicates = true
    @State private var savePaymentReminder = false
    @State private var reminderDueDateLocal: Date = Day.toLocal(Day.add(21, to: Day.today))
    @State private var reminderDateEdited = false
    @State private var savedReminderDate: Date?
    @State private var isImporting = false
    @State private var editingTransactionID: String?
    @State private var importResult: PDFImportResult?
    @State private var importError: String?

    private var canSaveReminderOnly: Bool {
        savePaymentReminder && selectedExistingCardID != nil && Day.fromLocal(reminderDueDateLocal) >= store.today
    }

    private var selectedExistingCardID: String? {
        if case .existing(let id) = target { return id }
        return nil
    }

    /// Cached: a multi-year CSV has thousands of rows, too many to re-match on every render.
    @State private var duplicateIDs: Set<String> = []

    private func refreshDuplicates() {
        guard let statement else { duplicateIDs = []; return }
        duplicateIDs = store.duplicateIDs(
            for: statement.transactions,
            onCardID: selectedExistingCardID,
            skipCrossSource: skipCrossSourceDuplicates
        )
    }

    private var importableCount: Int {
        guard let statement else { return 0 }
        let dupes = duplicateIDs
        return statement.transactions.filter { $0.include && !dupes.contains($0.id) }.count
    }

    private var selectedDuplicateCount: Int {
        guard let statement else { return 0 }
        let dupes = duplicateIDs
        return statement.transactions.filter { $0.include && dupes.contains($0.id) }.count
    }

    private var newProduct: CardProduct { Catalog.product(newCardProductID) }

    var body: some View {
        NavigationStack {
            Group {
                if statement != nil {
                    reviewForm
                } else if needsPassword {
                    passwordView
                } else {
                    pickerLandingView
                }
            }
            .navigationTitle(format.title)
            .onChange(of: statement) { refreshDuplicates() }
            .onChange(of: target) { refreshDuplicates() }
            .onChange(of: skipCrossSourceDuplicates) { refreshDuplicates() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if statement != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(importableCount > 0 ? "Import \(importableCount)" : "Save reminder") {
                            Task { await performImport() }
                        }
                        .disabled(isImporting || (importableCount == 0 && !canSaveReminderOnly))
                    }
                }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: format.contentTypes) { result in
                handlePickedFile(result)
            }
            .sheet(isPresented: Binding(
                get: { editingTransactionID != nil },
                set: { if !$0 { editingTransactionID = nil } }
            )) {
                if let editID = editingTransactionID,
                   let idx = statement?.transactions.firstIndex(where: { $0.id == editID }) {
                    PDFTransactionEditSheet(transaction: Binding(
                        get: { statement!.transactions[idx] },
                        set: { statement?.transactions[idx] = $0 }
                    ))
                }
            }
            .alert("Import complete", isPresented: Binding(
                get: { importResult != nil },
                set: { if !$0 { importResult = nil } }
            )) {
                Button("Done") { dismiss() }
            } message: {
                if let r = importResult {
                    let added = "\(r.inserted.formatted()) transaction\(r.inserted == 1 ? "" : "s") added"
                    let skipped = r.skippedDuplicates > 0
                        ? " (\(r.skippedDuplicates) duplicate\(r.skippedDuplicates == 1 ? "" : "s") skipped)"
                        : ""
                    let reminderNote = savedReminderDate.map { " Payment reminder set for \(Day.format($0))." } ?? ""
                    let base = r.inserted > 0 || savedReminderDate == nil
                        ? "\(added)\(skipped). Benefits and welcome offers have been refreshed."
                        : "No new transactions were needed."
                    Text("\(base)\(reminderNote)")
                }
            }
            .alert("Import failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - Step 1: Choose PDF

    private var pickerLandingView: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: format.icon)
                        .font(.system(size: 42))
                        .foregroundStyle(.indigo)
                    Text(format.title)
                        .font(.headline)
                    Text("Your statement is parsed entirely on this iPhone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Skipping import leaves these transactions out of your ledger.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button {
                        parseError = nil
                        pickingFile = true
                    } label: {
                        Label("Choose \(format.pickerLabel) from Files", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            if let parseError {
                Section {
                    Label(parseError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Works best with") {
                switch format {
                case .csv:
                    Label("The CSV activity download from American Express Canada, for any date range", systemImage: "checkmark.circle")
                    Label("Card-linked offer credits are recognized from the export's offer labels", systemImage: "tag")
                case .ofx:
                    Label("An OFX or QFX export for one USD or CAD credit card", systemImage: "checkmark.circle")
                    Label("Review the card and transactions before importing", systemImage: "list.bullet")
                case .pdf:
                    Label("Digital monthly statement PDFs downloaded from your issuer's app or website", systemImage: "checkmark.circle")
                    Label("Cards without Plaid support (Home Trust, Robinhood, Bilt, Apple Card, Wealthsimple, Rogers, PC Financial, Triangle, MBNA)", systemImage: "creditcard")
                }
                Label("Re-importing overlapping activity skips duplicate transactions automatically", systemImage: "arrow.triangle.2.circlepath")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 1b: Password Prompt

    private var passwordView: some View {
        Form {
            Section {
                if let fileName {
                    LabeledContent("File", value: fileName)
                }
                SecureField("PDF password", text: $password)
                    .textContentType(.password)
                    .onSubmit { unlockAndParse() }
                Button("Unlock locally") { unlockAndParse() }
                    .disabled(password.isEmpty)
            } header: {
                Text("Password-protected PDF")
            } footer: {
                Text("Used only in memory on this iPhone to open the PDF. The password is never stored.")
            }

            if let parseError {
                Section {
                    Label(parseError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button("Choose a different PDF") {
                    resetDocumentState()
                    pickingFile = true
                }
            }
        }
    }

    // MARK: - Step 2: Review & Confirm

    private var reviewForm: some View {
        let stmt = statement!
        let dupes = duplicateIDs
        return Form {
            Section("Statement summary") {
                if let fileName {
                    LabeledContent("File", value: fileName)
                }
                if let issuer = stmt.detectedIssuer {
                    LabeledContent("Detected issuer", value: issuer)
                }
                if let mask = stmt.accountMask {
                    LabeledContent("Card ending", value: "•••• \(mask)")
                }
                if let start = stmt.statementPeriodStart, let end = stmt.statementPeriodEnd {
                    LabeledContent(format == .pdf ? "Billing period" : "Date range", value: "\(Day.format(start)) – \(Day.format(end))")
                } else if let closing = stmt.statementClosingDate {
                    LabeledContent("Statement date", value: Day.format(closing))
                }
                if let due = stmt.paymentDueDate {
                    LabeledContent("Payment due", value: Day.format(due))
                }
                Picker("Statement currency", selection: $statementCurrency) {
                    ForEach(CurrencyCode.allCases) { c in
                        Text(c.rawValue).tag(c)
                    }
                }
                .onChange(of: statementCurrency) { _, newCurrency in
                    if statement?.currency != newCurrency { applyCurrency(newCurrency) }
                }

                Button("Choose another file") {
                    resetDocumentState()
                    pickingFile = true
                }
                .font(.callout)
            }

            if !stmt.warnings.isEmpty {
                Section("Heads up") {
                    ForEach(stmt.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }

            targetCardSection(statement: stmt)

            paymentReminderSection(statement: stmt)

            if selectedExistingCardID != nil {
                Section {
                    Toggle("Skip matching existing transactions", isOn: $skipCrossSourceDuplicates)
                } footer: {
                    if selectedDuplicateCount > 0 {
                        Text("\(selectedDuplicateCount) selected transaction\(selectedDuplicateCount == 1 ? "" : "s") already appear on this card and will be skipped.")
                    } else {
                        Text("Matches exact re-imports and existing Plaid or imported rows within ±2 days with the same amount.")
                    }
                }
            }

            transactionsSection(statement: stmt, dupes: dupes)
        }
    }

    @ViewBuilder
    private func targetCardSection(statement stmt: ParsedPDFStatement) -> some View {
        Section {
            if store.mode == .live && !store.cards.isEmpty {
                Picker("Target card", selection: $target) {
                    ForEach(store.cards) { card in
                        let suffix = card.mask.map { " (•••• \($0))" } ?? ""
                        Text("\(card.nickname)\(suffix)").tag(ImportTarget.existing(card.id))
                    }
                    Text("Create new card…").tag(ImportTarget.newCard)
                }
            }

            if case .existing(let cardID) = target, let card = store.card(cardID) {
                let cardMarket = Catalog.product(card.productID).market
                if cardMarket != statementCurrency {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.left.arrow.right.circle")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("This card is in \(cardMarket.rawValue), while the statement is set to \(statementCurrency.rawValue).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Switch statement currency to \(cardMarket.rawValue)") {
                                statementCurrency = cardMarket
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                }
            }

            if case .newCard = target {
                Picker("Market", selection: $newCardMarket) {
                    Text("United States").tag(CurrencyCode.usd)
                    Text("Canada").tag(CurrencyCode.cad)
                }
                .pickerStyle(.segmented)
                .onChange(of: newCardMarket) { _, m in
                    if Catalog.product(newCardProductID).market != m {
                        newCardProductID = Catalog.products(market: m).first { $0.issuer != "Other" }?.id
                            ?? (m == .cad ? "custom-ca" : "custom-us")
                    }
                }

                ProductPicker(
                    selection: $newCardProductID,
                    market: newCardMarket,
                    bank: Catalog.issuer(matching: stmt.detectedIssuer, market: newCardMarket)
                )

                TextField(newProduct.name, text: $newCardNickname)

                TextField("Last digits (optional)", text: $newCardMask)
                    .keyboardType(.numberPad)
                    .onChange(of: newCardMask) { _, v in
                        let digits = String(v.filter(\.isNumber).prefix(5))
                        if digits != v { newCardMask = digits }
                    }

                DatePicker("Opened", selection: $newCardOpenedOn, displayedComponents: .date)
            }
        } header: {
            Text("Import into")
        } footer: {
            if store.mode == .sample {
                Text("Importing into a new card starts your live local ledger and replaces the sample data.")
            } else if case .newCard = target {
                Text("Never enter the full card number; last 4 digits help match future statements.")
            }
        }
    }

    @ViewBuilder
    private func paymentReminderSection(statement stmt: ParsedPDFStatement) -> some View {
        Section {
            Toggle(stmt.paymentDueDate != nil ? "Remind me before payment is due" : "Add payment due reminder",
                   isOn: $savePaymentReminder)
            if savePaymentReminder {
                // Only a change made through the picker counts as an edit; dates set when a file is parsed don't.
                DatePicker("Payment due", selection: Binding(
                    get: { reminderDueDateLocal },
                    set: { reminderDueDateLocal = $0; reminderDateEdited = true }
                ), displayedComponents: .date)
            }
        } header: {
            Text("Payment reminder")
        } footer: {
            if savePaymentReminder {
                let due = Day.fromLocal(reminderDueDateLocal)
                if due < store.today {
                    Text("This due date is already in the past; no new alert will be scheduled.")
                } else if !store.statementRemindersAllowed {
                    Text("The due date is saved, but Bill payment alerts are off in Settings, so no notification will be sent.")
                } else {
                    Text("Schedules local reminders at 9 AM, 3 days before and on \(Day.format(due)). Lock-screen messages omit card details.")
                }
            } else if let due = stmt.paymentDueDate, due < store.today {
                Text("Detected due date (\(Day.format(due))) has already passed.")
            } else if format == .csv && stmt.paymentDueDate == nil {
                Text("This CSV doesn't include a payment due date. Turn this on to schedule a local reminder on this iPhone.")
            } else {
                Text("No payment due date was detected in this file. Turn this on to set one manually.")
            }
        }
    }

    @ViewBuilder
    private func transactionsSection(statement stmt: ParsedPDFStatement, dupes: Set<String>) -> some View {
        Section {
            if stmt.transactions.isEmpty {
                ContentUnavailableView(
                    "No transactions found",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Try another monthly statement PDF downloaded directly from your card issuer.")
                )
            } else {
                HStack {
                    let allSelected = stmt.transactions.allSatisfy(\.include)
                    Button(allSelected ? "Deselect all" : "Select all") {
                        setAllIncluded(!allSelected)
                    }
                    .font(.callout)
                    Spacer()
                    Text("\(stmt.transactions.count) parsed · \(importableCount) new")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(stmt.transactions) { tx in
                    let isDuplicate = dupes.contains(tx.id)
                    HStack(spacing: 10) {
                        Button {
                            toggleInclude(tx.id)
                        } label: {
                            Image(systemName: tx.include ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(tx.include ? (isDuplicate ? Color.secondary : Color.accentColor) : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tx.include ? "Exclude \(tx.merchant)" : "Include \(tx.merchant)")

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(tx.merchant)
                                    .font(.body)
                                    .lineLimit(1)
                                    .foregroundStyle(tx.include && !isDuplicate ? .primary : .secondary)
                                if isDuplicate {
                                    Text("Duplicate")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 4) {
                                Text(Day.format(tx.posted, .dateTime.month(.abbreviated).day().year()))
                                Text("· \(tx.kind.title)")
                                if tx.kind == .purchase || tx.kind == .refund {
                                    Text("· \(tx.category.title)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(tx.originalDescription)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 6)

                        Button {
                            editingTransactionID = tx.id
                        } label: {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(tx.amount.formatted)
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(tx.amount.minor < 0 ? .green : (tx.include && !isDuplicate ? .primary : .secondary))
                                Text("Edit")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Transactions")
        } footer: {
            if !stmt.transactions.isEmpty && importableCount == 0 {
                Text("Select at least one non-duplicate transaction to import.")
            } else if !stmt.transactions.isEmpty {
                Text("Tap an amount to edit a row's merchant, sign, kind, or category before importing.")
            }
        }
    }

    // MARK: - Actions

    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            parseError = error.localizedDescription
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                self.fileName = url.lastPathComponent
                self.parseError = nil
                let data = try Data(contentsOf: url, options: format == .ofx ? .mappedIfSafe : [])
                switch format {
                case .pdf:
                    self.pdfData = data
                    self.password = ""
                    self.needsPassword = false
                    parseLoadedPDF(data: data, password: nil)
                case .csv:
                    applyParsedStatement(try CSVStatementParser.parse(data: data))
                case .ofx:
                    applyParsedStatement(try OFXStatementParser.parse(data: data))
                }
            } catch {
                store.recordParserFailure(formatName: format.rawValue, error: error)
                if error is OFXStatementError || error is CSVStatementError {
                    parseError = error.localizedDescription
                } else {
                    parseError = format == .pdf ? PDFStatementError.unreadablePDF.localizedDescription : "This file could not be read."
                }
            }
        }
    }

    private func unlockAndParse() {
        guard let pdfData else { return }
        parseError = nil
        parseLoadedPDF(data: pdfData, password: password)
    }

    private func parseLoadedPDF(data: Data, password: String?) {
        let fallbackCurrency: CurrencyCode? = preselectedCardID
            .flatMap { store.card($0) }
            .map { Catalog.product($0.productID).market }
            ?? preselectedProduct?.market
        do {
            let parsed = try PDFStatementParser.parse(
                data: data,
                password: password,
                fallbackCurrency: fallbackCurrency,
                referenceToday: store.today
            )
            self.needsPassword = false
            self.password = ""
            self.parseError = nil
            applyParsedStatement(parsed)
        } catch let error as PDFStatementError {
            store.recordParserFailure(formatName: "pdf", error: error)
            switch error {
            case .passwordRequired:
                self.needsPassword = true
                self.parseError = nil
            case .invalidPassword:
                self.needsPassword = true
                self.parseError = error.localizedDescription
            case .unreadablePDF, .noSelectableText:
                self.needsPassword = false
                self.parseError = error.localizedDescription
            }
        } catch {
            store.recordParserFailure(formatName: "pdf", error: error)
            self.needsPassword = false
            self.parseError = error.localizedDescription
        }
    }

    private func applyParsedStatement(_ parsed: ParsedPDFStatement) {
        if parsed.transactions.isEmpty {
            store.recordParserFailure(formatName: format.rawValue, code: .noTransactions)
        }
        self.statement = parsed
        self.statementCurrency = parsed.currency

        // Choose target card: explicit preselection > auto-matched existing live card > new card.
        if let pre = preselectedCardID, store.mode == .live, store.card(pre) != nil {
            self.target = .existing(pre)
        } else if let suggested = store.suggestedCardID(for: parsed),
                  preselectedProduct == nil || store.card(suggested)?.productID == preselectedProductID {
            self.target = .existing(suggested)
        } else {
            self.target = .newCard
        }

        // Pre-populate new-card draft in case the owner creates a new card.
        self.newCardMarket = preselectedProduct?.market ?? parsed.currency
        if let preselectedProduct {
            self.newCardProductID = preselectedProduct.id
        } else if let detectedProductID = parsed.detectedProductID {
            self.newCardProductID = detectedProductID
        } else {
            self.newCardProductID = parsed.currency == .cad ? "custom-ca" : "custom-us"
        }
        self.newCardNickname = ""
        self.newCardMask = parsed.accountMask ?? ""
        let earliest = parsed.transactions.map(\.posted).min() ?? parsed.statementPeriodStart ?? Day.addMonths(-12, to: store.today)
        self.newCardOpenedOn = Day.toLocal(earliest)

        // Pre-populate payment due reminder when the PDF/CSV supplied an upcoming due date.
        self.reminderDateEdited = false
        self.savedReminderDate = nil
        if let due = parsed.paymentDueDate {
            self.reminderDueDateLocal = Day.toLocal(due)
            self.savePaymentReminder = due >= store.today
        } else {
            self.reminderDueDateLocal = Day.toLocal(Day.add(21, to: store.today))
            self.savePaymentReminder = false
        }
    }

    private func applyCurrency(_ newCurrency: CurrencyCode) {
        guard var stmt = statement else { return }
        stmt.currency = newCurrency
        for i in stmt.transactions.indices {
            stmt.transactions[i].amount = Money(stmt.transactions[i].amount.minor, newCurrency)
        }
        statement = stmt
        if case .newCard = target {
            newCardMarket = newCurrency
        }
    }

    private func toggleInclude(_ id: String) {
        guard let idx = statement?.transactions.firstIndex(where: { $0.id == id }) else { return }
        statement?.transactions[idx].include.toggle()
    }

    private func setAllIncluded(_ included: Bool) {
        guard var stmt = statement else { return }
        for i in stmt.transactions.indices {
            stmt.transactions[i].include = included
        }
        statement = stmt
    }

    private func resetDocumentState() {
        pdfData = nil
        fileName = nil
        password = ""
        needsPassword = false
        parseError = nil
        statement = nil
        savePaymentReminder = false
        reminderDateEdited = false
        savedReminderDate = nil
    }

    private func performImport() async {
        guard let stmt = statement, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let result: PDFImportResult
            switch target {
            case .existing(let cardID):
                if importableCount > 0 {
                    result = try store.importPDFStatement(
                        transactions: stmt.transactions,
                        intoExistingCardID: cardID,
                        skipCrossSourceDuplicates: skipCrossSourceDuplicates
                    )
                } else {
                    result = PDFImportResult(cardID: cardID, inserted: 0, skippedDuplicates: selectedDuplicateCount)
                }
            case .newCard:
                let trimmed = newCardNickname.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalName = trimmed.isEmpty ? newProduct.name : trimmed
                result = try store.importPDFStatementIntoNewCard(
                    transactions: stmt.transactions,
                    nickname: finalName,
                    productID: newCardProductID,
                    mask: (4...5).contains(newCardMask.count) ? newCardMask : nil,
                    openedOn: Day.fromLocal(newCardOpenedOn),
                    skipCrossSourceDuplicates: skipCrossSourceDuplicates
                )
            }
            if savePaymentReminder {
                let due = Day.fromLocal(reminderDueDateLocal)
                let billSource: StatementBill.Source = (stmt.paymentDueDate != nil && !reminderDateEdited)
                    ? (format == .csv ? .csv : .pdf)
                    : .manual
                let saved = await store.saveStatementBill(
                    cardID: result.cardID,
                    dueDate: due,
                    statementDate: format.reminderStatementDate(for: stmt),
                    source: billSource,
                    forceReplace: reminderDateEdited
                )
                savedReminderDate = saved && due >= store.today ? due : nil
            } else {
                savedReminderDate = nil
            }
            importResult = result
            onImported?()
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// Lightweight editor to adjust a parsed transaction row's merchant, date, sign, kind, or category before importing.
private struct PDFTransactionEditSheet: View {
    @Binding var transaction: ParsedPDFTransaction
    @Environment(\.dismiss) private var dismiss

    @State private var merchant: String
    @State private var postedLocal: Date
    @State private var amountText: String
    @State private var isNegative: Bool
    @State private var kind: TransactionKind
    @State private var category: RewardCategory

    init(transaction: Binding<ParsedPDFTransaction>) {
        _transaction = transaction
        let t = transaction.wrappedValue
        _merchant = State(initialValue: t.merchant)
        _postedLocal = State(initialValue: Day.toLocal(t.posted))
        _amountText = State(initialValue: String(format: "%.2f", Double(abs(t.amount.minor)) / 100.0))
        _isNegative = State(initialValue: t.amount.minor < 0)
        _kind = State(initialValue: t.kind)
        _category = State(initialValue: t.category)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Transaction") {
                    TextField("Merchant", text: $merchant)
                    DatePicker("Posted date", selection: $postedLocal, displayedComponents: .date)
                    HStack {
                        Text(transaction.amount.currency.rawValue)
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                    }
                    Picker("Direction", selection: $isNegative) {
                        Text("Charge / money out (+)").tag(false)
                        Text("Credit / refund / payment (−)").tag(true)
                    }
                    Picker("Kind", selection: $kind) {
                        ForEach(TransactionKind.allCases, id: \.self) { k in
                            Text(k.title).tag(k)
                        }
                    }
                    if kind == .purchase || kind == .refund {
                        Picker("Category", selection: $category) {
                            ForEach(RewardCategory.allCases) { c in
                                Label(c.title, systemImage: c.symbol).tag(c)
                            }
                        }
                    }
                }

                Section("Statement line") {
                    Text(transaction.originalDescription)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("Page \(transaction.page)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("Edit row")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let cleanedMerchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleanedMerchant.isEmpty {
                            transaction.merchant = cleanedMerchant
                        }
                        transaction.posted = Day.fromLocal(postedLocal)
                        if let parsedAmount = Double(amountText.replacingOccurrences(of: ",", with: "")),
                           parsedAmount.isFinite, parsedAmount > 0 {
                            let minor = Int((parsedAmount * 100).rounded()) * (isNegative ? -1 : 1)
                            transaction.amount = Money(minor, transaction.amount.currency)
                        }
                        transaction.kind = kind
                        transaction.category = (kind == .purchase || kind == .refund) ? category : .other
                        dismiss()
                    }
                }
            }
        }
    }
}
