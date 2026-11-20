import SwiftUI
import UniformTypeIdentifiers

/// FileDocument wrapper for exporting raw bytes of an encrypted `.cardledger` archive via SwiftUI's file exporter.
struct EncryptedArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else {
            throw LedgerArchiveError.invalidFormat
        }
        data = bytes
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Sheet to create and save a passphrase-encrypted archive of the local ledger.
struct LedgerArchiveExportView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase = ""
    @State private var confirmedPassphrase = ""
    @State private var working = false
    @State private var error: String?
    @State private var exportDocument: EncryptedArchiveDocument?
    @State private var showingExporter = false
    @State private var exportSaved = false

    private var passphraseValid: Bool {
        let count = LedgerArchive.passphraseLength(passphrase)
        return count >= LedgerArchive.minimumPassphraseLength
            && count <= LedgerArchive.maximumPassphraseLength
            && passphrase == confirmedPassphrase
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Exports your cards, transactions, benefit review decisions, category overrides, welcome offers, certificates, statement reminders, and settings into one encrypted file.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Sign-in tokens, Plaid access tokens, and your device database key are never included.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("What is included")
                }

                Section {
                    SecureField("Passphrase", text: $passphrase)
                        .textContentType(.newPassword)
                        .disabled(working)
                    SecureField("Confirm passphrase", text: $confirmedPassphrase)
                        .textContentType(.newPassword)
                        .disabled(working)
                    if !confirmedPassphrase.isEmpty && passphrase != confirmedPassphrase {
                        Text("The passphrases differ.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Encryption passphrase")
                } footer: {
                    Text("Use at least \(LedgerArchive.minimumPassphraseLength) characters. Store this passphrase safely — Card Ledger cannot recover an archive if you lose it.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await createArchive() }
                    } label: {
                        HStack {
                            Text("Create encrypted archive…")
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(working || !passphraseValid)
                }
            }
            .navigationTitle("Export encrypted archive")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(working)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(working)
                }
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .data,
                defaultFilename: LedgerArchive.defaultFilename(today: store.today)
            ) { result in
                exportDocument = nil
                switch result {
                case .success:
                    exportSaved = true
                case .failure(let err):
                    if (err as NSError).code != NSUserCancelledError {
                        error = err.localizedDescription
                    }
                }
            }
            .alert("Archive saved", isPresented: $exportSaved) {
                Button("Done") { dismiss() }
            } message: {
                Text("Your encrypted ledger archive has been saved. Keep your passphrase in a password manager so you can restore it later.")
            }
            .onDisappear {
                passphrase = ""
                confirmedPassphrase = ""
                exportDocument = nil
            }
        }
    }

    private func createArchive() async {
        guard !working else { return }
        working = true
        error = nil
        let secret = passphrase
        defer { working = false }
        do {
            let bytes = try await store.exportEncryptedArchive(passphrase: secret)
            passphrase = ""
            confirmedPassphrase = ""
            exportDocument = EncryptedArchiveDocument(data: bytes)
            showingExporter = true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Sheet to pick, unlock, preview, and atomically restore a passphrase-encrypted `.cardledger` archive.
struct LedgerArchiveRestoreView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pickingFile = false
    @State private var archiveData: Data?
    @State private var fileName: String?
    @State private var passphrase = ""
    @State private var unlockedSnapshot: LedgerSnapshot?
    @State private var confirmReplace = false
    @State private var working = false
    @State private var error: String?
    @State private var restored = false

    var body: some View {
        NavigationStack {
            Form {
                if let snapshot = unlockedSnapshot {
                    previewContent(snapshot)
                } else if archiveData != nil {
                    unlockContent
                } else {
                    pickFileContent
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Restore archive")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(working)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(working)
                }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.data, .item]) { result in
                handlePickedFile(result)
            }
            .confirmationDialog(
                "Replace local ledger?",
                isPresented: $confirmReplace,
                titleVisibility: .visible
            ) {
                Button("Replace local ledger", role: .destructive) {
                    performRestore()
                }
            } message: {
                Text("This overwrites all cards, transactions, review decisions, overrides, and settings currently stored on this iPhone with the archive contents.")
            }
            .alert("Ledger restored", isPresented: $restored) {
                Button("Done") { dismiss() }
            } message: {
                Text("Your cards, transactions, decisions, overrides, and settings have been restored to this iPhone.")
            }
            .onDisappear {
                reset()
            }
        }
    }

    private var pickFileContent: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "lock.doc")
                    .font(.system(size: 42))
                    .foregroundStyle(.indigo)
                Text("Restore from an encrypted archive")
                    .font(.headline)
                Text("Choose a .cardledger file you previously exported. It is decrypted and checked in memory before any change is made to this iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    error = nil
                    pickingFile = true
                } label: {
                    Label("Choose archive from Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private var unlockContent: some View {
        Group {
            Section {
                if let fileName {
                    LabeledContent("File", value: fileName)
                }
                SecureField("Archive passphrase", text: $passphrase)
                    .textContentType(.password)
                    .disabled(working)
                    .onSubmit { Task { await unlock() } }
                Button {
                    Task { await unlock() }
                } label: {
                    HStack {
                        Text("Unlock archive")
                        if working {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(working || passphrase.isEmpty)
            } header: {
                Text("Decrypt archive")
            } footer: {
                Text("A wrong passphrase or damaged file is rejected without modifying your existing ledger.")
            }

            Section {
                Button("Choose a different file") {
                    reset()
                    pickingFile = true
                }
                .disabled(working)
            }
        }
    }

    @ViewBuilder
    private func previewContent(_ snapshot: LedgerSnapshot) -> some View {
        let summary = snapshot.summary
        Section("Archive contents") {
            if let fileName {
                LabeledContent("File", value: fileName)
            }
            if let exportedAt = summary.exportedAt {
                LabeledContent("Exported", value: exportedAt.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("Cards", value: summary.cardCount.formatted())
            LabeledContent("Transactions", value: summary.transactionCount.formatted())
            LabeledContent("Review decisions", value: summary.decisionCount.formatted())
            LabeledContent("Category overrides", value: summary.overrideCount.formatted())
            if summary.welcomeOfferCount > 0 {
                LabeledContent("Welcome offers", value: summary.welcomeOfferCount.formatted())
            }
            if summary.certificateCount > 0 {
                LabeledContent("Certificates", value: summary.certificateCount.formatted())
            }
        }

        Section {
            let busyWithSync = store.isSyncing || store.isRefreshingBills
            if store.mode == .live {
                Button("Replace local ledger…", role: .destructive) {
                    confirmReplace = true
                }
                .disabled(working || busyWithSync)
            } else {
                Button("Restore ledger") {
                    performRestore()
                }
                .disabled(working || busyWithSync)
            }
            Button("Choose a different file") {
                reset()
                pickingFile = true
            }
            .disabled(working)
        } footer: {
            if store.isSyncing || store.isRefreshingBills {
                Text("Wait for the current bank sync to finish before restoring an archive.")
            } else {
                Text(store.mode == .live
                     ? "Restoring replaces every card, transaction, decision, override, and setting stored on this iPhone."
                     : "Restoring replaces the sample data with your archived ledger.")
            }
        }
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let err):
            error = err.localizedDescription
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                guard values.isDirectory != true else {
                    error = LedgerArchiveError.invalidFormat.localizedDescription
                    return
                }
                if let size = values.fileSize, size > LedgerArchive.maximumArchiveBytes {
                    error = LedgerArchiveError.fileTooLarge.localizedDescription
                    return
                }
                let data = try Data(contentsOf: url)
                guard data.count <= LedgerArchive.maximumArchiveBytes else {
                    error = LedgerArchiveError.fileTooLarge.localizedDescription
                    return
                }
                archiveData = data
                fileName = url.lastPathComponent
                passphrase = ""
                unlockedSnapshot = nil
                error = nil
            } catch {
                self.error = "This file could not be read."
            }
        }
    }

    private func unlock() async {
        guard let data = archiveData, !passphrase.isEmpty, !working else { return }
        working = true
        error = nil
        let secret = passphrase
        defer {
            working = false
            passphrase = ""
        }
        do {
            unlockedSnapshot = try await store.inspectEncryptedArchive(data, passphrase: secret)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performRestore() {
        guard let snapshot = unlockedSnapshot, !working else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try store.restoreArchive(snapshot)
            restored = true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func reset() {
        archiveData = nil
        fileName = nil
        passphrase = ""
        unlockedSnapshot = nil
        error = nil
    }
}
