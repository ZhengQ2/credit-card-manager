import Foundation

@MainActor
extension Store {
    static let parserFailuresSettingKey = "diagnostics.parser_failures"
    static let maxStoredParserFailures = 30

    /// Records a closed, privacy-safe statement parser failure code for diagnostics reports.
    /// Never stores file names, statement text, amounts, or passwords.
    func recordParserFailure(formatName: String, error: Error, now: Date = Date()) {
        let format = ParserFormat(formatName: formatName)
        guard let code = ParserFailureCode.from(format: format, error: error) else { return }
        recordParserFailure(format: format, code: code, now: now)
    }

    func recordParserFailure(formatName: String, code: ParserFailureCode, now: Date = Date()) {
        recordParserFailure(format: ParserFormat(formatName: formatName), code: code, now: now)
    }

    func recordParserFailure(format: ParserFormat, code: ParserFailureCode, now: Date = Date()) {
        let iso = ISO8601DateFormatter()
        let event = ParserFailureEvent(recordedAt: iso.string(from: now), format: format, code: code)
        parserFailures.append(event)
        if parserFailures.count > Self.maxStoredParserFailures {
            parserFailures = Array(parserFailures.suffix(Self.maxStoredParserFailures))
        }
        persistParserFailures()
    }

    func clearParserFailures() {
        parserFailures = []
        try? repo?.setSetting(Self.parserFailuresSettingKey, nil)
    }

    func loadParserFailures(from repo: LedgerRepository) {
        guard let raw = repo.setting(Self.parserFailuresSettingKey)?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ParserFailureEvent].self, from: raw) else {
            parserFailures = []
            return
        }
        parserFailures = Array(decoded.suffix(Self.maxStoredParserFailures))
    }

    private func persistParserFailures() {
        guard let data = try? JSONEncoder().encode(parserFailures) else { return }
        try? repo?.setSetting(Self.parserFailuresSettingKey, String(decoding: data, as: UTF8.self))
    }

    /// Builds a strictly allowlisted diagnostics report without any transaction descriptions,
    /// amounts, account numbers, nicknames, emails, or tokens.
    func buildDiagnosticsReport(
        includeMetricKit: Bool = false,
        refreshAPIHealth: Bool = false,
        metricKitCollector: MetricKitCollector = .shared,
        bundle: Bundle = .main,
        now: Date = Date()
    ) async -> DiagnosticsReport {
        let iso = ISO8601DateFormatter()
        var apiVersion = client.lastKnownAPIVersion
        var healthStatus: String

        if let session = serviceSession {
            if refreshAPIHealth {
                do {
                    let health = try await client.health(baseURL: session.baseURL)
                    apiVersion = health.apiVersion
                    healthStatus = "ok"
                } catch ServiceError.unreachable {
                    healthStatus = "unreachable"
                } catch {
                    healthStatus = "error"
                }
            } else {
                healthStatus = apiVersion == nil ? "not_checked" : "cached"
            }
        } else {
            healthStatus = "not_signed_in"
        }

        let appVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
        let appBuild = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let storedConnections = ((try? repo?.connections()) ?? []).sorted { ($0.institution, $0.id) < ($1.institution, $1.id) }
        let connectionStates: [DiagnosticsReport.ConnectionSyncState] = storedConnections.enumerated().map { idx, conn in
            let accounts = (try? repo?.accounts(connection: conn.id)) ?? []
            let mappedCount = accounts.filter { $0.isCreditCard && $0.cardID != nil }.count
            let unmappedCount = accounts.filter { $0.needsMapping }.count
            let ignoredCount = accounts.filter { $0.ignored }.count
            let billStatus = DiagnosticsReport.billReportStatusLabel(
                report: billReports[conn.id],
                withdrawalPending: billWithdrawalPending(conn.id)
            )
            return DiagnosticsReport.ConnectionSyncState(
                index: idx + 1,
                institution: DiagnosticsReport.sanitizedInstitution(conn.institution),
                country: conn.country,
                environment: conn.environment,
                status: conn.status,
                historyStatus: conn.historyStatus,
                hasCursor: conn.cursor != nil,
                lastSyncAt: conn.lastSync.map { iso.string(from: $0) },
                mappedCreditCardCount: mappedCount,
                unmappedCreditCardCount: unmappedCount,
                ignoredAccountCount: ignoredCount,
                lastSyncErrorCode: lastSyncErrorCodes[conn.id],
                billReportStatus: billStatus
            )
        }

        let metricKitSection: DiagnosticsReport.MetricKitSection?
        if includeMetricKit {
            let payloads = metricKitCollector.summaries()
            metricKitSection = DiagnosticsReport.MetricKitSection(
                includedByConsent: true,
                payloadCount: payloads.count,
                payloads: payloads
            )
        } else {
            metricKitSection = nil
        }

        return DiagnosticsReport(
            reportVersion: DiagnosticsReport.currentReportVersion,
            generatedAt: iso.string(from: now),
            app: DiagnosticsReport.AppInfo(
                version: appVersion,
                build: appBuild,
                osVersion: osVersion,
                ledgerMode: mode == .live ? "live" : "sample",
                storageAvailable: storageError == nil
            ),
            api: DiagnosticsReport.APIInfo(
                signedIn: isSignedIn,
                environment: serviceEnvironment,
                apiVersion: apiVersion,
                healthStatus: healthStatus,
                billAlertsEnabled: billAlertsEnabled
            ),
            connections: connectionStates,
            parserFailures: parserFailures,
            metricKit: metricKitSection
        )
    }
}
