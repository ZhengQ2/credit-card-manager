import Foundation

enum ServiceError: Error, LocalizedError, Equatable {
    case notSignedIn
    case unreachable
    case tlsError(String)
    case unauthorized
    case loginRequired
    case notReady
    case rateLimited
    case server(code: String, retryable: Bool)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to your Card Ledger account in Settings first."
        case .unreachable: "Card Ledger's service is offline or unreachable."
        case .tlsError(let detail): "Secure connection to the service failed: \(detail)"
        case .unauthorized: "You've been signed out. Sign in again in Settings."
        case .loginRequired: "The bank needs you to sign in again."
        case .notReady: "The bank is still preparing transaction history."
        case .rateLimited: "Too many requests. Try again shortly."
        case .server("scoped_sync_required", _): "Update the Card Ledger service to sync individual credit cards."
        case .server("connection_limit_reached", _): "You've reached the limit for bank connections. Disconnect a bank in Cards before adding another."
        case .server("bill_consent_expired", _): "This authorization expired. Start again to share bill dates."
        case .server(let code, _): "Service error: \(code)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .unreachable, .rateLimited, .notReady: true
        case .server(_, let r): r
        default: false
        }
    }
}

/// The signed-in account. Stored in a device-only Keychain item. The short-lived access token is never stored.
struct AccountSession: Codable, Equatable {
    var baseURL: URL
    var environment: String
    var userID: String
    var email: String
    var refreshToken: String
}

struct RemoteAccount: Codable, Hashable {
    let id: String
    let name: String
    let officialName: String?
    let mask: String?
    let type: String
    let subtype: String?
    let currency: String?
}

struct RemoteConnection: Codable, Hashable {
    let connectionId: String
    let institution: String?
    let country: String
    let status: String
    let accounts: [RemoteAccount]
    let lastSuccessfulPull: String?
    /// Plaid reported new transactions via webhook since the last full sync.
    let updatesAvailable: Bool?
}

struct SyncPageResponse: Decodable {
    let status: String
    let accountId: String?
    let added: [RemoteTransaction]?
    let modified: [RemoteTransaction]?
    let removed: [String]?
    let nextCursor: String?
    let hasMore: Bool?
    let historyStatus: String?
}

/// Talks to the Card Ledger API over HTTPS (design §6–7). Ephemeral session: no URL cache, no cookies.
///
/// Auth: completed sign-in yields a 15-minute access token and a rotating refresh token. Requests refresh
/// the access token shortly before it expires, and once more on a 401. Refreshes are single-flight because the
/// service revokes the session if a rotated refresh token is ever presented again.
@MainActor
final class ServiceClient {
    /// Production API. Debug builds can point at a local mock service from the sign-in screen.
    nonisolated static let defaultBaseURL = URL(string: "https://api.zhengqiu.net")!

    private let session: URLSession
    private let auth = AuthState()
    private var changingSecurity = false
    private(set) var account: AccountSession?
    /// Invoked when the service invalidates the session (e.g. refresh returned 401) so `Store` stays in sync.
    var onSessionEnded: (@MainActor () -> Void)?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        // Pre-accounts device pairings can't authenticate against the accounts API.
        Keychain.delete(.serviceCredential)
        if let data = Keychain.data(.accountSession) {
            account = try? JSONDecoder().decode(AccountSession.self, from: data)
        }
    }

    var isSignedIn: Bool { account != nil }
    var environment: String? { account?.environment }

    // MARK: Sign-in

    struct Health: Decodable {
        let ok: Bool
        let service: String
        let apiVersion: Int?
        let environment: String
        let signIn: [String]?
    }
    struct TokenResponse: Decodable {
        struct User: Decodable { let id: String; let email: String }
        let accessToken: String
        let accessTokenExpiresIn: Int
        let refreshToken: String
        let user: User
    }

    struct SecondFactor: Decodable { let id: String }
    private enum FirstFactorVerification: Decodable {
        case secondFactor(SecondFactor), tokens(TokenResponse)

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            if let challenge = try fields.decodeIfPresent(SecondFactor.self, forKey: .secondFactor) {
                self = .secondFactor(challenge)
            } else {
                self = .tokens(try TokenResponse(from: decoder))
            }
        }

        private enum CodingKeys: CodingKey { case secondFactor }
    }

    struct SecurityStatus: Decodable {
        struct Passkey: Decodable, Identifiable {
            let id: String
            let createdAt: String
        }
        let totpEnabled: Bool
        let passwordEnabled: Bool
        let passkeysEnabled: Bool
        let passkeys: [Passkey]
    }
    struct TOTPSetup: Decodable { let id: String; let secret: String; let uri: String }
    struct PasskeyChallenge: Decodable { let id: String; let rpID: String; let challenge: String }
    struct PasskeyRegistration: Decodable {
        let id: String
        let rpID: String
        let challenge: String
        let userID: String
        let name: String
        let excludedCredentialIDs: [String]
    }

    func health(baseURL: URL) async throws -> Health {
        let health: Health = try await request("GET", "/v1/health", base: baseURL, auth: false)
        guard health.ok, health.service == "card-ledger-api", (health.apiVersion ?? 0) >= 2 else {
            throw ServiceError.server(code: "not_a_card_ledger_service", retryable: false)
        }
        return health
    }

    func startSignIn(baseURL: URL, email: String) async throws -> Health {
        let health = try await health(baseURL: baseURL)
        struct Sent: Decodable { let sent: Bool }
        let _: Sent = try await request("POST", "/v1/auth/email/start", body: ["email": email], base: baseURL, auth: false)
        return health
    }

    func completeSignIn(baseURL: URL, environment: String, email: String, code: String) async throws -> SecondFactor? {
        try await verifyFirstFactor(path: "/v1/auth/email/verify", baseURL: baseURL, environment: environment,
                                    fields: ["email": email, "code": code])
    }

    func signInWithPassword(baseURL: URL, environment: String, email: String, password: String) async throws -> SecondFactor? {
        try await verifyFirstFactor(path: "/v1/auth/password/verify", baseURL: baseURL, environment: environment,
                                    fields: ["email": email, "password": password])
    }

    private func verifyFirstFactor(path: String, baseURL: URL, environment: String, fields: [String: String]) async throws -> SecondFactor? {
        let result: FirstFactorVerification = try await request("POST", path, body: fields, base: baseURL, auth: false)
        switch result {
        case .secondFactor(let challenge): return challenge
        case .tokens(let tokens):
            try saveSession(tokens, baseURL: baseURL, environment: environment)
            return nil
        }
    }

    func completeSecondFactor(baseURL: URL, environment: String, id: String, code: String) async throws {
        let body: [String: Any] = ["id": id, "code": code]
        let tokens: TokenResponse = try await request("POST", "/v1/auth/totp/verify", body: body, base: baseURL, auth: false)
        try saveSession(tokens, baseURL: baseURL, environment: environment)
    }

    func startPasskeySignIn(baseURL: URL) async throws -> PasskeyChallenge {
        try await request("POST", "/v1/auth/passkeys/start", base: baseURL, auth: false)
    }

    func completePasskeySignIn(baseURL: URL, environment: String, id: String, credential: [String: Any]) async throws {
        let body: [String: Any] = ["id": id, "credential": credential]
        let tokens: TokenResponse = try await request("POST", "/v1/auth/passkeys/verify", body: body, base: baseURL, auth: false)
        try saveSession(tokens, baseURL: baseURL, environment: environment)
    }

    func securityStatus() async throws -> SecurityStatus { try await request("GET", "/v1/auth/security") }
    func startTOTP() async throws -> TOTPSetup { try await request("POST", "/v1/auth/totp/setup") }

    func enableTOTP(id: String, code: String) async throws -> [String] {
        struct Enabled: Decodable { let tokens: TokenResponse; let recoveryCodes: [String] }
        let body: [String: Any] = ["id": id, "code": code]
        return try await changeSecurity {
            let response: Enabled = try await request("POST", "/v1/auth/totp/enable", body: body)
            return (response.tokens, response.recoveryCodes)
        }
    }

    func disableTOTP() async throws { try await changeSecurity("DELETE", "/v1/auth/totp") }

    func setPassword(_ password: String) async throws {
        try await changeSecurity("PUT", "/v1/auth/password", fields: ["password": password])
    }

    func removePassword() async throws { try await changeSecurity("DELETE", "/v1/auth/password") }

    func startPasskeyRegistration() async throws -> PasskeyRegistration {
        try await request("POST", "/v1/auth/passkeys/registration/start")
    }

    func registerPasskey(id: String, credential: [String: Any]) async throws -> SecurityStatus {
        try await request("POST", "/v1/auth/passkeys/registration/verify", body: ["id": id, "credential": credential])
    }

    func removePasskey(id: String) async throws { try await changeSecurity("DELETE", "/v1/auth/passkeys/\(id)") }

    private func changeSecurity(_ method: String, _ path: String, fields: [String: String] = [:]) async throws {
        try await changeSecurity {
            let tokens: TokenResponse = try await request(method, path, body: fields.isEmpty ? nil : fields)
            return (tokens, ())
        }
    }

    private func changeSecurity<Result>(_ update: () async throws -> (TokenResponse, Result)) async throws -> Result {
        guard let current = account else { throw ServiceError.notSignedIn }
        guard !changingSecurity else { throw ServiceError.server(code: "security_changed", retryable: true) }
        changingSecurity = true
        defer { changingSecurity = false }
        let (tokens, result) = try await update()
        try saveSession(tokens, baseURL: current.baseURL, environment: current.environment)
        return result
    }

    private func saveSession(_ t: TokenResponse, baseURL: URL, environment: String) throws {
        let saved = AccountSession(baseURL: baseURL, environment: environment, userID: t.user.id, email: t.user.email,
                                   refreshToken: t.refreshToken)
        guard Keychain.set(try JSONEncoder().encode(saved), for: .accountSession) else {
            throw ServiceError.server(code: "keychain_save_failed", retryable: false)
        }
        account = saved
        auth.replace(token: t.accessToken, expiresIn: t.accessTokenExpiresIn)
    }

    /// Ends the session on the service (best effort) and forgets it here.
    func signOut() async {
        if account != nil {
            struct R: Decodable { let ok: Bool }
            let _: R? = try? await request("POST", "/v1/auth/sign-out")
        }
        forget(notify: false)
    }

    /// Deletes the account on the service: every bank connection is removed at Plaid first.
    func deleteAccount() async throws {
        struct R: Decodable { let deleted: Bool }
        let _: R = try await request("DELETE", "/v1/me")
        forget(notify: false)
    }

    /// Forgets the session on this iPhone only (fresh install, or the service already ended it).
    func forgetLocally() { forget(notify: false) }

    private func forget(notify: Bool = false) {
        let hadAccount = account != nil
        Keychain.delete(.accountSession)
        account = nil
        auth.replace(token: nil, expiresIn: 0)
        if notify && hadAccount { onSessionEnded?() }
    }

    /// Returns a valid access token, refreshing it (single-flight) when it is missing or about to expire.
    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard account != nil else { throw ServiceError.notSignedIn }
        if !forceRefresh, let token = auth.validToken() { return token }
        return try await auth.refreshOnce { [self] in
            try Task.checkCancellation()
            guard let latest = account else { throw ServiceError.notSignedIn }
            do {
                let t: TokenResponse = try await self.request("POST", "/v1/auth/refresh", body: ["refreshToken": latest.refreshToken],
                                                              base: latest.baseURL, auth: false)
                try Task.checkCancellation()
                var updated = latest
                updated.refreshToken = t.refreshToken
                updated.email = t.user.email
                if Keychain.set(try JSONEncoder().encode(updated), for: .accountSession) { self.account = updated }
                return (t.accessToken, t.accessTokenExpiresIn)
            } catch ServiceError.unauthorized {
                try Task.checkCancellation()
                // A security change revokes the old session before its replacement reaches the app.
                if !changingSecurity { forget(notify: true) }
                throw ServiceError.unauthorized
            }
        }
    }

    // MARK: API

    struct LinkToken: Decodable {
        let linkToken: String
        let expiration: String
        let environment: String
        let billConsentId: String?
    }

    func linkToken(country: String, connectionID: String? = nil, billAccess: Bool = false, historyDays: Int = 365) async throws -> LinkToken {
        var body: [String: Any] = ["country": country]
        if let connectionID { body["connectionId"] = connectionID }
        else { body["historyDays"] = historyDays }
        if billAccess { body["billAccess"] = true }
        do { return try await request("POST", "/v1/credit-card-link-token", body: body) }
        catch ServiceError.server("not_found", _) {
            throw ServiceError.server(code: "scoped_sync_required", retryable: false)
        }
    }

    /// Sandbox/mock only: a public token without the Link UI.
    func testPublicToken(country: String) async throws -> String {
        struct R: Decodable { let publicToken: String }
        let r: R = try await request("POST", "/v1/dev/public-token", body: ["country": country])
        return r.publicToken
    }

    func createConnection(publicToken: String, clientRequestID: String, country: String) async throws -> RemoteConnection {
        try await request("POST", "/v1/connections", body: ["publicToken": publicToken, "clientRequestId": clientRequestID, "country": country])
    }

    func connections() async throws -> [RemoteConnection] {
        struct R: Decodable { let connections: [RemoteConnection] }
        let r: R = try await request("GET", "/v1/connections")
        return r.connections
    }

    func syncPage(connectionID: String, accountID: String, cursor: String?) async throws -> SyncPageResponse {
        do {
            return try await request("POST", "/v1/connections/\(connectionID)/card-sync",
                                     body: ["accountId": accountID, "cursor": cursor ?? NSNull()])
        } catch ServiceError.server("not_found", _) {
            throw ServiceError.server(code: "scoped_sync_required", retryable: false)
        }
    }

    func creditCardBills(connectionID: String, accountIDs: [String]) async throws -> CreditCardBills {
        try await request("POST", "/v1/connections/\(connectionID)/credit-card-bills", body: ["accountIds": accountIDs])
    }

    func confirmBillAccess(connectionID: String, consentID: String) async throws {
        struct Result: Decodable { let ok: Bool }
        let _: Result = try await request("POST", "/v1/connections/\(connectionID)/bill-consent", body: ["consentId": consentID])
    }

    func withdrawBillAccess(connectionID: String) async throws {
        struct Result: Decodable { let ok: Bool }
        let _: Result = try await request("DELETE", "/v1/connections/\(connectionID)/bill-consent")
    }

    func disconnect(connectionID: String) async throws {
        struct R: Decodable { let status: String }
        let _: R = try await request("DELETE", "/v1/connections/\(connectionID)")
    }

    // MARK: Transport

    private func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil,
                                       base: URL? = nil, auth: Bool = true) async throws -> T {
        guard auth else { return try await send(method, path, body: body, base: base, bearer: nil) }
        guard let account else { throw ServiceError.notSignedIn }
        let version = self.auth.version
        let url = base ?? account.baseURL
        func authenticatedSend(forceRefresh: Bool) async throws -> T {
            let bearer = try await accessToken(forceRefresh: forceRefresh)
            guard version == self.auth.version else { throw CancellationError() }
            let result: T = try await send(method, path, body: body, base: url, bearer: bearer)
            guard version == self.auth.version else { throw CancellationError() }
            return result
        }
        do {
            return try await authenticatedSend(forceRefresh: false)
        } catch ServiceError.unauthorized {
            // The access token may have been revoked or the clock skewed: refresh once and retry.
            guard self.account != nil else { throw ServiceError.unauthorized }
            guard version == self.auth.version else { throw CancellationError() }
            do {
                return try await authenticatedSend(forceRefresh: true)
            } catch ServiceError.unauthorized {
                if !changingSecurity, version == self.auth.version { forget(notify: true) }
                throw ServiceError.unauthorized
            }
        }
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]?,
                                    base: URL?, bearer: String?) async throws -> T {
        guard let baseURL = base ?? account?.baseURL else { throw ServiceError.notSignedIn }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = trimmed.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch is CancellationError { throw CancellationError() }
        catch let e as URLError {
            switch e.code {
            case .cancelled:
                throw CancellationError()
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired,
                 .appTransportSecurityRequiresSecureConnection:
                throw ServiceError.tlsError(e.localizedDescription)
            default:
                throw ServiceError.unreachable
            }
        }
        catch { throw ServiceError.unreachable }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return try JSONDecoder().decode(T.self, from: data) }
        let err = try? JSONDecoder().decode(ServiceErrorBody.self, from: data)
        switch (status, err?.error) {
        case (401, "unauthorized"), (401, "refresh_invalid"), (401, "refresh_expired"), (401, "refresh_reused"):
            throw ServiceError.unauthorized
        case (409, "ITEM_LOGIN_REQUIRED"): throw ServiceError.loginRequired
        case (429, _): throw ServiceError.rateLimited
        default: throw ServiceError.server(code: err?.error ?? "http_\(status)", retryable: err?.retryable ?? (status >= 500))
        }
    }
}

private struct ServiceErrorBody: Decodable { let error: String; let retryable: Bool? }

/// Holds the in-memory access token and serializes refreshes.
@MainActor
private final class AuthState {
    private var token: String?
    private var expiresAt = Date.distantPast
    private var inFlight: Task<String, Error>?
    private(set) var version = 0

    func validToken() -> String? {
        guard let token, expiresAt.timeIntervalSinceNow > 60 else { return nil }
        return token
    }

    func replace(token: String?, expiresIn: Int) {
        version &+= 1
        inFlight?.cancel()
        inFlight = nil
        self.token = token
        expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
    }

    func refreshOnce(_ refresh: @MainActor @escaping () async throws -> (String, Int)) async throws -> String {
        if let inFlight { return try await inFlight.value }
        let version = self.version
        let task = Task { () throws -> String in
            let (token, ttl) = try await refresh()
            try Task.checkCancellation()
            self.token = token
            self.expiresAt = Date().addingTimeInterval(TimeInterval(ttl))
            return token
        }
        inFlight = task
        defer { if version == self.version { inFlight = nil } }
        return try await task.value
    }
}
