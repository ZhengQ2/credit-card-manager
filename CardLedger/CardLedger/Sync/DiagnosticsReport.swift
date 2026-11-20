import CoreTransferable
import Foundation
import UniformTypeIdentifiers
#if canImport(MetricKit)
import MetricKit
#endif

/// Strictly allowlisted sync error codes for diagnostics reports.
/// Never stores raw localized error descriptions or server response bodies.
enum DiagnosticsSyncErrorCode: String, Codable, Equatable, Sendable {
    case notSignedIn = "not_signed_in"
    case unreachable = "unreachable"
    case tlsError = "tls_error"
    case unauthorized = "unauthorized"
    case loginRequired = "login_required"
    case notReady = "not_ready"
    case rateLimited = "rate_limited"
    case scopedSyncRequired = "scoped_sync_required"
    case connectionLimitReached = "connection_limit_reached"
    case billConsentExpired = "bill_consent_expired"
    case connectionUnavailable = "connection_unavailable"
    case paginationMutated = "pagination_kept_mutating"
    case invalidService = "not_a_card_ledger_service"
    case serverError = "server_error"
    case unknownError = "unknown_error"

    static func from(_ error: Error) -> Self {
        guard let serviceError = error as? ServiceError else { return .unknownError }
        switch serviceError {
        case .notSignedIn: return .notSignedIn
        case .unreachable: return .unreachable
        case .tlsError: return .tlsError
        case .unauthorized: return .unauthorized
        case .loginRequired: return .loginRequired
        case .notReady: return .notReady
        case .rateLimited: return .rateLimited
        case .server(let code, _):
            switch code {
            case "scoped_sync_required": return .scopedSyncRequired
            case "connection_limit_reached": return .connectionLimitReached
            case "bill_consent_expired": return .billConsentExpired
            case "connection_not_found", "connection_disconnected", "ITEM_NOT_FOUND": return .connectionUnavailable
            case "pagination_kept_mutating": return .paginationMutated
            case "not_a_card_ledger_service": return .invalidService
            default:
                // SyncEngine maps closed-connection errors to a user-facing sentence inside `.server(code:)`.
                if code.contains("no longer available") { return .connectionUnavailable }
                return .serverError
            }
        }
    }
}

/// Strictly allowlisted statement parser failure codes for diagnostics reports.
/// Never records file names, statement lines, transaction descriptions, amounts, or passwords.
enum ParserFormat: String, Codable, Equatable, Sendable {
    case pdf
    case csv
    case ofx
    case unknown

    init(formatName: String) {
        self = Self(rawValue: formatName.lowercased()) ?? .unknown
    }
}

enum ParserFailureCode: String, Codable, Equatable, Sendable {
    case pdfUnreadable = "pdf_unreadable"
    case pdfInvalidPassword = "pdf_invalid_password"
    case pdfNoSelectableText = "pdf_no_selectable_text"
    case csvUnreadable = "csv_unreadable"
    case csvUnsupportedFormat = "csv_unsupported_format"
    case csvNoRows = "csv_no_rows"
    case ofxUnreadable = "ofx_unreadable"
    case ofxTooLarge = "ofx_too_large"
    case ofxUnsupportedStatement = "ofx_unsupported_statement"
    case ofxMultipleAccounts = "ofx_multiple_accounts"
    case ofxUnsupportedCurrency = "ofx_unsupported_currency"
    case ofxNoUsableTransactions = "ofx_no_usable_transactions"
    case noTransactions = "no_transactions"
    case fileUnreadable = "file_unreadable"
    case unknownError = "unknown_error"

    /// Maps a parser error into a closed, privacy-safe failure code.
    /// Returns `nil` for non-failure prompts (such as `.passwordRequired`).
    static func from(format: ParserFormat, error: Error) -> Self? {
        if let pdfError = error as? PDFStatementError {
            switch pdfError {
            case .passwordRequired: return nil
            case .unreadablePDF: return .pdfUnreadable
            case .invalidPassword: return .pdfInvalidPassword
            case .noSelectableText: return .pdfNoSelectableText
            }
        }
        if let csvError = error as? CSVStatementError {
            switch csvError {
            case .unreadable: return .csvUnreadable
            case .unsupportedFormat: return .csvUnsupportedFormat
            case .noRows: return .csvNoRows
            }
        }
        if let ofxError = error as? OFXStatementError {
            switch ofxError {
            case .unreadable: return .ofxUnreadable
            case .tooLarge: return .ofxTooLarge
            case .unsupportedStatement: return .ofxUnsupportedStatement
            case .multipleAccounts: return .ofxMultipleAccounts
            case .unsupportedCurrency: return .ofxUnsupportedCurrency
            case .noUsableTransactions: return .ofxNoUsableTransactions
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            return .fileUnreadable
        }
        return .unknownError
    }
}

struct ParserFailureEvent: Codable, Equatable, Sendable {
    let recordedAt: String
    let format: ParserFormat
    let code: ParserFailureCode
}

/// Privacy-safe summary of one iOS MetricKit diagnostic payload (crashes and hangs only).
struct MetricKitDiagnosticSummary: Codable, Equatable, Sendable {
    struct CrashSummary: Codable, Equatable, Sendable {
        let appVersion: String
        let osVersion: String
        let signal: Int?
        let exceptionType: Int?
        let exceptionCode: Int?
        let terminationReason: String?
        let callStackTreeJSON: String?
    }

    struct HangSummary: Codable, Equatable, Sendable {
        let appVersion: String
        let osVersion: String
        let hangDurationMs: Int
        let callStackTreeJSON: String?
    }

    let windowStart: String
    let windowEnd: String
    let appVersion: String?
    let crashes: [CrashSummary]
    let hangs: [HangSummary]
    let cpuExceptionCount: Int
    let diskWriteExceptionCount: Int
}

/// Allowlist-only diagnostics report attached to tester feedback (CL-14).
/// Contains ONLY app/API versions, per-connection sync state, parser failure codes,
/// and opt-in MetricKit crash/hang summaries — never transactions, amounts, account numbers, or tokens.
struct DiagnosticsReport: Codable, Equatable, Sendable {
    struct AppInfo: Codable, Equatable, Sendable {
        let version: String
        let build: String
        let osVersion: String
        let ledgerMode: String
        let storageAvailable: Bool
    }

    struct APIInfo: Codable, Equatable, Sendable {
        let signedIn: Bool
        let environment: String?
        let apiVersion: Int?
        let healthStatus: String
        let billAlertsEnabled: Bool
    }

    struct ConnectionSyncState: Codable, Equatable, Sendable {
        let index: Int
        let institution: String
        let country: String
        let environment: String
        let status: String
        let historyStatus: String?
        let hasCursor: Bool
        let lastSyncAt: String?
        let mappedCreditCardCount: Int
        let unmappedCreditCardCount: Int
        let ignoredAccountCount: Int
        let lastSyncErrorCode: DiagnosticsSyncErrorCode?
        let billReportStatus: String?
    }

    struct MetricKitSection: Codable, Equatable, Sendable {
        let includedByConsent: Bool
        let payloadCount: Int
        let payloads: [MetricKitDiagnosticSummary]
    }

    let reportVersion: Int
    let generatedAt: String
    let app: AppInfo
    let api: APIInfo
    let connections: [ConnectionSyncState]
    let parserFailures: [ParserFailureEvent]
    let metricKit: MetricKitSection?

    static let currentReportVersion = 1

    func formattedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func formattedJSONString() -> String {
        guard let data = try? formattedJSON() else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func defaultFilename(today: Date = Day.today) -> String {
        "CardLedger-Diagnostics-\(Day.key(today)).json"
    }

    /// Sanitizes an institution display name so long or unexpected values are bounded.
    static func sanitizedInstitution(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Unknown" }
        return String(cleaned.prefix(80))
    }

    /// Maps persisted bill-report / withdrawal state into a fixed allowlisted status label.
    static func billReportStatusLabel(report: BillReport?, withdrawalPending: Bool) -> String? {
        if withdrawalPending { return "withdrawal_pending" }
        return report?.response.status.rawValue
    }
}

/// Shareable `.json` file representation for attaching a diagnostics report via SwiftUI `ShareLink`.
struct DiagnosticsExportFile: Transferable, Sendable {
    let filename: String
    let data: Data

    static let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CardLedgerDiagnostics", isDirectory: true)

    /// Deletes report files written for sharing. iOS clears temporary files only when space runs low.
    static func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            let dir = DiagnosticsExportFile.temporaryDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(item.filename)
            try item.data.write(to: url, options: [.atomic, .completeFileProtection])
            return SentTransferredFile(url)
        }
    }
}

/// Receives iOS MetricKit crash and hang diagnostic payloads locally so testers can opt in
/// to attach them with a feedback report. Never uploads anything automatically.
// Thread-safe: all mutable state is guarded by `lock`.
final class MetricKitCollector: NSObject, @unchecked Sendable {
    static let shared = MetricKitCollector()

    static let maxStoredPayloads = 10
    static let maxDiagnosticsPerPayload = 5
    static let maxCallStackBytes = 8_192

    private let lock = NSLock()
    private let storageURL: URL?
    private var started = false
    private var storedPayloads: [MetricKitDiagnosticSummary] = []

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        super.init()
        loadFromDisk()
    }

    /// Kept out of the ledger folder: opening the database resets every file there to complete protection,
    /// and MetricKit can deliver while the phone is locked.
    static func defaultStorageURL() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return base.appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent("metrickit.json")
    }

    func start() {
        lock.lock()
        let shouldRegister = !started
        started = true
        lock.unlock()
        guard shouldRegister else { return }
        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif
    }

    func summaries() -> [MetricKitDiagnosticSummary] {
        lock.lock()
        defer { lock.unlock() }
        return storedPayloads
    }

    func record(_ summaries: [MetricKitDiagnosticSummary]) {
        guard !summaries.isEmpty else { return }
        lock.lock()
        storedPayloads.append(contentsOf: summaries)
        if storedPayloads.count > Self.maxStoredPayloads {
            storedPayloads = Array(storedPayloads.suffix(Self.maxStoredPayloads))
        }
        let snapshot = storedPayloads
        lock.unlock()
        saveToDisk(snapshot)
    }

    func clear() {
        lock.lock()
        storedPayloads = []
        lock.unlock()
        if let storageURL {
            try? FileManager.default.removeItem(at: storageURL)
        }
    }

    private func loadFromDisk() {
        guard let storageURL,
              let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([MetricKitDiagnosticSummary].self, from: data) else {
            return
        }
        lock.lock()
        storedPayloads = Array(decoded.suffix(Self.maxStoredPayloads))
        lock.unlock()
    }

    private func saveToDisk(_ payloads: [MetricKitDiagnosticSummary]) {
        guard let storageURL, let data = try? JSONEncoder().encode(payloads) else { return }
        let dir = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        // MetricKit can deliver while the phone is locked, when a file with complete protection can't be written.
        try? data.write(to: storageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = storageURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func boundedJSON(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if data.count <= maxCallStackBytes {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: data.prefix(maxCallStackBytes), as: UTF8.self) + "…(truncated)"
    }

    private static func boundedReason(_ reason: String?) -> String? {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            return nil
        }
        return String(reason.prefix(200))
    }
}

#if canImport(MetricKit)
extension MetricKitCollector: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        // Only crash and hang diagnostics are collected for opt-in feedback reports.
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let iso = ISO8601DateFormatter()
        let converted: [MetricKitDiagnosticSummary] = payloads.compactMap { payload -> MetricKitDiagnosticSummary? in
            let crashes = (payload.crashDiagnostics ?? []).prefix(Self.maxDiagnosticsPerPayload).map { crash in
                MetricKitDiagnosticSummary.CrashSummary(
                    appVersion: crash.metaData.applicationBuildVersion,
                    osVersion: crash.metaData.osVersion,
                    signal: crash.signal?.intValue,
                    exceptionType: crash.exceptionType?.intValue,
                    exceptionCode: crash.exceptionCode?.intValue,
                    terminationReason: Self.boundedReason(crash.terminationReason),
                    callStackTreeJSON: Self.boundedJSON(crash.callStackTree.jsonRepresentation())
                )
            }
            let hangs = (payload.hangDiagnostics ?? []).prefix(Self.maxDiagnosticsPerPayload).map { hang in
                let ms = Int(hang.hangDuration.converted(to: .milliseconds).value.rounded())
                return MetricKitDiagnosticSummary.HangSummary(
                    appVersion: hang.metaData.applicationBuildVersion,
                    osVersion: hang.metaData.osVersion,
                    hangDurationMs: max(0, ms),
                    callStackTreeJSON: Self.boundedJSON(hang.callStackTree.jsonRepresentation())
                )
            }
            let cpuCount = payload.cpuExceptionDiagnostics?.count ?? 0
            let diskCount = payload.diskWriteExceptionDiagnostics?.count ?? 0
            guard !crashes.isEmpty || !hangs.isEmpty || cpuCount > 0 || diskCount > 0 else { return nil }
            let appVersion = payload.crashDiagnostics?.first?.applicationVersion
                ?? payload.hangDiagnostics?.first?.applicationVersion
                ?? payload.cpuExceptionDiagnostics?.first?.applicationVersion
                ?? payload.diskWriteExceptionDiagnostics?.first?.applicationVersion
            return MetricKitDiagnosticSummary(
                windowStart: iso.string(from: payload.timeStampBegin),
                windowEnd: iso.string(from: payload.timeStampEnd),
                appVersion: appVersion,
                crashes: crashes,
                hangs: hangs,
                cpuExceptionCount: cpuCount,
                diskWriteExceptionCount: diskCount
            )
        }
        record(converted)
    }
}
#endif
