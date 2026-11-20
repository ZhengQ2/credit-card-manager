import XCTest
@testable import CardLedger

final class DiagnosticsReportTests: XCTestCase {
    private func makeTempDirectory(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    func testDiagnosticsReportIncludesRequiredMetadataAndNeverLeaksSensitiveData() async throws {
        let dir = try makeTempDirectory(prefix: "cl-diag")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = Store(today: Day.make(2026, 11, 20), databaseDirectory: dir)
        let repo = try XCTUnwrap(store.repo)

        // Populate sensitive canaries across every local table to verify none enter the diagnostics JSON.
        let conn = StoredConnection(
            id: "conn-canary-secret-id",
            institution: "Synthetic Bank",
            country: "CA",
            environment: "production",
            status: "active",
            cursor: #"{"acc-canary":"CANARY-SECRET-CURSOR-XYZ"}"#,
            lastSync: Date(timeIntervalSince1970: 1_795_100_000),
            historyStatus: "COMPLETE"
        )
        let mappedAcc = SourceAccount(
            id: "acc-canary-mapped-id",
            connectionID: conn.id,
            name: "CANARY PLATINUM ACCOUNT NAME",
            mask: "10088",
            type: "credit",
            subtype: "credit card",
            currency: "CAD",
            cardID: nil,
            ignored: false
        )
        let ignoredAcc = SourceAccount(
            id: "acc-canary-ignored-id",
            connectionID: conn.id,
            name: "CANARY HIDDEN ACCOUNT",
            mask: "4532",
            type: "credit",
            subtype: "credit card",
            currency: "CAD",
            cardID: nil,
            ignored: false
        )
        try repo.saveConnection(conn, accounts: [mappedAcc, ignoredAcc])
        try repo.confirmMapping(
            connection: conn.id,
            [(account: mappedAcc, productID: "amex-cobalt-ca", nickname: "CANARY-NICKNAME-COBALT")]
        )
        try repo.setIgnored(true, accounts: [ignoredAcc.id])

        let batch = SyncBatch(
            pages: [
                SyncPageDelta(
                    added: [
                        RemoteTransaction(
                            id: "tx-canary-secret-1",
                            accountId: mappedAcc.id,
                            amountMinor: 4250,
                            currency: "CAD",
                            currencyIsOfficial: true,
                            date: "2026-11-12",
                            authorizedDate: "2026-11-11",
                            name: "CANARY METRO GROCERY",
                            merchantName: "CANARY METRO",
                            originalDescription: "CANARY ORIG DESC 9876543210",
                            categoryPrimary: "FOOD_AND_DRINK",
                            categoryDetailed: "FOOD_AND_DRINK_GROCERIES",
                            merchantCategoryCode: "5411",
                            pending: false,
                            pendingTransactionId: nil
                        ),
                    ],
                    modified: [],
                    removed: []
                )
            ],
            historyStatus: "COMPLETE"
        )
        try repo.apply(batch, connection: conn.id, cursor: #"{"acc-canary":"CANARY-SECRET-CURSOR-XYZ"}"#)

        let cardID = try XCTUnwrap(try repo.loadCards().first?.id)
        try repo.saveWelcomeOffer(
            WelcomeOffer(
                id: "offer-canary",
                cardID: cardID,
                kind: .spendBonus,
                currency: .cad,
                start: Day.make(2026, 1, 1),
                months: 6,
                minSpend: Money(300_000, .cad),
                points: 30_000,
                cash: nil,
                extraMultiplier: nil,
                categories: [],
                spendCap: nil,
                notes: "CANARY WELCOME OFFER SECRET",
                markedEarned: false
            ),
            currency: .cad
        )
        try repo.addUsage(UsageLog(
            id: "usage-canary",
            periodID: "p|\(cardID)|2026-11-01",
            amount: Money(1500, .cad),
            usedOn: Day.make(2026, 11, 5),
            note: "CANARY USAGE SECRET NOTE"
        ))
        try repo.saveCertificate(AwardCertificate(
            id: "cert-canary",
            cardID: cardID,
            ruleID: "free-night",
            issuedOn: Day.make(2026, 1, 1),
            expiresOn: Day.make(2027, 1, 1),
            redeemedOn: nil,
            note: "CANARY CERT SECRET NOTE"
        ))

        // Record sync error with arbitrary raw string & parser failures with sensitive text in NSError.
        store.lastSyncErrorCodes[conn.id] = DiagnosticsSyncErrorCode.from(
            ServiceError.server(code: "CANARY-RAW-SERVER-MSG-999", retryable: false)
        )
        store.recordParserFailure(formatName: "pdf", error: PDFStatementError.noSelectableText)
        store.recordParserFailure(formatName: "csv", error: CSVStatementError.unsupportedFormat)
        store.recordParserFailure(
            formatName: "pdf",
            error: NSError(
                domain: "TestError",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Failed reading Statement_4532_JohnDoe.pdf with password CANARY-PASS"]
            )
        )

        store.reload()

        let collector = MetricKitCollector(storageURL: dir.appendingPathComponent("mk.json"))
        collector.record([
            MetricKitDiagnosticSummary(
                windowStart: "2026-11-19T00:00:00Z",
                windowEnd: "2026-11-20T00:00:00Z",
                appVersion: "0.1",
                crashes: [
                    .init(
                        appVersion: "1",
                        osVersion: "iOS 27.2",
                        signal: 11,
                        exceptionType: 1,
                        exceptionCode: 0,
                        terminationReason: "CANARY-METRICKIT-CRASH",
                        callStackTreeJSON: nil
                    )
                ],
                hangs: [],
                cpuExceptionCount: 0,
                diskWriteExceptionCount: 0
            )
        ])

        let report = await store.buildDiagnosticsReport(
            includeMetricKit: false,
            refreshAPIHealth: false,
            metricKitCollector: collector,
            now: Date(timeIntervalSince1970: 1_795_120_000)
        )

        // Verify required diagnostic fields are present and accurate.
        XCTAssertEqual(report.reportVersion, DiagnosticsReport.currentReportVersion)
        XCTAssertEqual(report.app.ledgerMode, "live")
        XCTAssertTrue(report.app.storageAvailable)
        XCTAssertFalse(report.app.version.isEmpty)
        XCTAssertFalse(report.app.build.isEmpty)
        XCTAssertEqual(report.connections.count, 1)
        XCTAssertEqual(report.connections[0].institution, "Synthetic Bank")
        XCTAssertEqual(report.connections[0].country, "CA")
        XCTAssertEqual(report.connections[0].status, "active")
        XCTAssertEqual(report.connections[0].historyStatus, "COMPLETE")
        XCTAssertTrue(report.connections[0].hasCursor)
        XCTAssertEqual(report.connections[0].mappedCreditCardCount, 1)
        XCTAssertEqual(report.connections[0].unmappedCreditCardCount, 0)
        XCTAssertEqual(report.connections[0].ignoredAccountCount, 1)
        XCTAssertEqual(report.connections[0].lastSyncErrorCode, .serverError)
        XCTAssertEqual(report.parserFailures.map(\.code), [.pdfNoSelectableText, .csvUnsupportedFormat, .unknownError])
        XCTAssertNil(report.metricKit, "MetricKit data must not be attached without explicit tester opt-in")

        // Verify ZERO sensitive canaries appear anywhere in the serialized diagnostics JSON.
        let json = report.formattedJSONString()
        let forbiddenSubstrings = [
            "conn-canary-secret-id",
            "acc-canary-mapped-id",
            "acc-canary-ignored-id",
            "CANARY-SECRET-CURSOR-XYZ",
            "CANARY PLATINUM ACCOUNT",
            "CANARY HIDDEN ACCOUNT",
            "CANARY-NICKNAME-COBALT",
            "10088",
            "4532",
            "tx-canary-secret-1",
            "CANARY METRO",
            "CANARY ORIG DESC",
            "9876543210",
            "4250",
            "42.50",
            "CANARY WELCOME OFFER",
            "CANARY USAGE SECRET",
            "CANARY CERT SECRET",
            "CANARY-RAW-SERVER-MSG",
            "Statement_4532_JohnDoe.pdf",
            "CANARY-PASS",
            "CANARY-METRICKIT-CRASH",
        ]
        for secret in forbiddenSubstrings {
            XCTAssertFalse(json.contains(secret), "Diagnostics report leaked sensitive value: \(secret)")
        }
    }

    @MainActor
    func testMetricKitOptInControlsInclusionAndPersistence() async throws {
        let dir = try makeTempDirectory(prefix: "cl-mk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mkURL = dir.appendingPathComponent("diagnostics-metrickit.json")

        let collector = MetricKitCollector(storageURL: mkURL)
        let summary = MetricKitDiagnosticSummary(
            windowStart: "2026-11-19T00:00:00Z",
            windowEnd: "2026-11-20T00:00:00Z",
            appVersion: "0.1",
            crashes: [
                .init(
                    appVersion: "1",
                    osVersion: "iOS 27.2",
                    signal: 11,
                    exceptionType: 1,
                    exceptionCode: 1,
                    terminationReason: "Namespace SIGNAL, Code 11",
                    callStackTreeJSON: #"{"callStacks":[]}"#
                )
            ],
            hangs: [
                .init(
                    appVersion: "1",
                    osVersion: "iOS 27.2",
                    hangDurationMs: 650,
                    callStackTreeJSON: #"{"callStacks":[]}"#
                )
            ],
            cpuExceptionCount: 0,
            diskWriteExceptionCount: 1
        )
        collector.record([summary])

        // Verify persistence across collector instances.
        let reloadedCollector = MetricKitCollector(storageURL: mkURL)
        XCTAssertEqual(reloadedCollector.summaries(), [summary])

        let store = Store(today: Day.make(2026, 11, 20), databaseDirectory: dir)
        let withoutConsent = await store.buildDiagnosticsReport(
            includeMetricKit: false,
            refreshAPIHealth: false,
            metricKitCollector: reloadedCollector
        )
        XCTAssertNil(withoutConsent.metricKit)

        let withConsent = await store.buildDiagnosticsReport(
            includeMetricKit: true,
            refreshAPIHealth: false,
            metricKitCollector: reloadedCollector
        )
        XCTAssertEqual(withConsent.metricKit?.includedByConsent, true)
        XCTAssertEqual(withConsent.metricKit?.payloadCount, 1)
        XCTAssertEqual(withConsent.metricKit?.payloads.first?.crashes.first?.signal, 11)
        XCTAssertEqual(withConsent.metricKit?.payloads.first?.hangs.first?.hangDurationMs, 650)

        reloadedCollector.clear()
        XCTAssertTrue(reloadedCollector.summaries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mkURL.path))
    }

    @MainActor
    func testParserFailureMappingAndRingBufferPersistence() throws {
        let dir = try makeTempDirectory(prefix: "cl-parser-diag")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Password prompt is not a failure.
        XCTAssertNil(ParserFailureCode.from(format: .pdf, error: PDFStatementError.passwordRequired))
        XCTAssertEqual(ParserFailureCode.from(format: .pdf, error: PDFStatementError.invalidPassword), .pdfInvalidPassword)
        XCTAssertEqual(ParserFailureCode.from(format: .pdf, error: PDFStatementError.unreadablePDF), .pdfUnreadable)
        XCTAssertEqual(ParserFailureCode.from(format: .csv, error: CSVStatementError.noRows), .csvNoRows)
        XCTAssertEqual(ParserFailureCode.from(format: .csv, error: CSVStatementError.unreadable), .csvUnreadable)
        XCTAssertEqual(ParserFailureCode.from(format: .ofx, error: OFXStatementError.multipleAccounts), .ofxMultipleAccounts)
        XCTAssertEqual(ParserFailureCode.from(format: .ofx, error: OFXStatementError.unsupportedCurrency), .ofxUnsupportedCurrency)
        XCTAssertEqual(ParserFailureCode.from(format: .ofx, error: OFXStatementError.noUsableTransactions), .ofxNoUsableTransactions)
        XCTAssertEqual(
            ParserFailureCode.from(format: .csv, error: NSError(domain: NSCocoaErrorDomain, code: 260)),
            .fileUnreadable
        )

        let store = Store(today: Day.make(2026, 11, 20), databaseDirectory: dir)
        for i in 0..<35 {
            store.recordParserFailure(
                format: i.isMultiple(of: 2) ? .pdf : .csv,
                code: i == 34 ? .noTransactions : .pdfUnreadable,
                now: Date(timeIntervalSince1970: 1_795_000_000 + Double(i))
            )
        }
        XCTAssertEqual(store.parserFailures.count, Store.maxStoredParserFailures)
        XCTAssertEqual(store.parserFailures.last?.code, .noTransactions)

        // Verify persistence across Store launches.
        let reloaded = Store(today: Day.make(2026, 11, 20), databaseDirectory: dir)
        XCTAssertEqual(reloaded.parserFailures.count, Store.maxStoredParserFailures)
        XCTAssertEqual(reloaded.parserFailures.last?.code, .noTransactions)
    }

    func testSyncErrorCodeSanitizesServerMessages() {
        XCTAssertEqual(DiagnosticsSyncErrorCode.from(ServiceError.notSignedIn), .notSignedIn)
        XCTAssertEqual(DiagnosticsSyncErrorCode.from(ServiceError.unreachable), .unreachable)
        XCTAssertEqual(DiagnosticsSyncErrorCode.from(ServiceError.tlsError("cert details")), .tlsError)
        XCTAssertEqual(DiagnosticsSyncErrorCode.from(ServiceError.unauthorized), .unauthorized)
        XCTAssertEqual(DiagnosticsSyncErrorCode.from(ServiceError.loginRequired), .loginRequired)
        XCTAssertEqual(DiagnosticsSyncErrorCode.from(ServiceError.notReady), .notReady)
        XCTAssertEqual(DiagnosticsSyncErrorCode.from(ServiceError.rateLimited), .rateLimited)
        XCTAssertEqual(
            DiagnosticsSyncErrorCode.from(ServiceError.server(code: "scoped_sync_required", retryable: false)),
            .scopedSyncRequired
        )
        XCTAssertEqual(
            DiagnosticsSyncErrorCode.from(ServiceError.server(code: "This bank connection is no longer available on your service.", retryable: false)),
            .connectionUnavailable
        )
        XCTAssertEqual(
            DiagnosticsSyncErrorCode.from(ServiceError.server(code: "arbitrary_secret_error_text", retryable: false)),
            .serverError
        )
    }
}
