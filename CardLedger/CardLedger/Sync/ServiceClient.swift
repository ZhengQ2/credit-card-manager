import Foundation
import UIKit

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
    let added: [RemoteTransaction]?
    let modified: [RemoteTransaction]?
    let removed: [String]?
    let nextCursor: String?
    let hasMore: Bool?
    let historyStatus: String?
}

/// Talks to the Card Ledger API over HTTPS (design §6–7). Ephemeral session: no URL cache, no cookies.
///
/// Auth: an email one-time code yields a 15-minute access token and a rotating refresh token. Requests refresh
/// the access token shortly before it expires, and once more on a 401. Refreshes are single-flight because the
/// service revokes the session if a rotated refresh token is ever presented again.
final class ServiceClient {
    /// Production API. Debug builds can point at a local mock service from the sign-in screen.
    static let defaultBaseURL = URL(string: "https://api.zhengqiu.net")!

    private let session: URLSession
    private let auth = AuthState()
    private(set) var account: AccountSession?

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

    struct Health: Decodable { let ok: Bool; let service: String; let apiVersion: Int?; let environment: String }
    struct TokenResponse: Decodable {
        struct User: Decodable { let id: String; let email: String }
        let accessToken: String
        let accessTokenExpiresIn: Int
        let refreshToken: String
        let user: User
    }

    /// Checks the service and emails a one-time code.
    func startSignIn(baseURL: URL, email: String) async throws -> Health {
        let health: Health = try await request("GET", "/v1/health", base: baseURL, auth: false)
        guard health.ok, health.service == "card-ledger-api", (health.apiVersion ?? 0) >= 2 else {
            throw ServiceError.server(code: "not_a_card_ledger_service", retryable: false)
        }
        struct Sent: Decodable { let sent: Bool }
        let _: Sent = try await request("POST", "/v1/auth/email/start", body: ["email": email], base: baseURL, auth: false)
        return health
    }

    /// Exchanges the emailed code for tokens and stores the session in the Keychain.
    func completeSignIn(baseURL: URL, environment: String, email: String, code: String) async throws {
        let body: [String: Any] = ["email": email, "code": code, "deviceName": await UIDevice.current.name]
        let t: TokenResponse = try await request("POST", "/v1/auth/email/verify", body: body, base: baseURL, auth: false)
        let saved = AccountSession(baseURL: baseURL, environment: environment, userID: t.user.id, email: t.user.email,
                                   refreshToken: t.refreshToken)
        guard Keychain.set(try JSONEncoder().encode(saved), for: .accountSession) else {
            throw ServiceError.server(code: "keychain_save_failed", retryable: false)
        }
        account = saved
        await auth.set(token: t.accessToken, expiresIn: t.accessTokenExpiresIn)
    }

    /// Ends the session on the service (best effort) and forgets it here.
    func signOut() async {
        if account != nil {
            struct R: Decodable { let ok: Bool }
            let _: R? = try? await request("POST", "/v1/auth/sign-out")
        }
        forget()
    }

    /// Deletes the account on the service: every bank connection is removed at Plaid first.
    func deleteAccount() async throws {
        struct R: Decodable { let deleted: Bool }
        let _: R = try await request("DELETE", "/v1/me")
        forget()
    }

    /// Forgets the session on this iPhone only (fresh install, or the service already ended it).
    func forgetLocally() { forget() }

    private func forget() {
        Keychain.delete(.accountSession)
        account = nil
        Task { await auth.clear() }
    }

    /// Returns a valid access token, refreshing it (single-flight) when it is missing or about to expire.
    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = account else { throw ServiceError.notSignedIn }
        if !forceRefresh, let token = await auth.validToken() { return token }
        return try await auth.refreshOnce { [self] in
            let latest = self.account ?? current
            do {
                let t: TokenResponse = try await self.request("POST", "/v1/auth/refresh", body: ["refreshToken": latest.refreshToken],
                                                              base: latest.baseURL, auth: false)
                var updated = latest
                updated.refreshToken = t.refreshToken
                updated.email = t.user.email
                if Keychain.set(try JSONEncoder().encode(updated), for: .accountSession) { self.account = updated }
                return (t.accessToken, t.accessTokenExpiresIn)
            } catch ServiceError.unauthorized {
                self.forget()
                throw ServiceError.unauthorized
            } catch ServiceError.server(let code, _) where code.hasPrefix("refresh_") {
                self.forget()
                throw ServiceError.unauthorized
            }
        }
    }

    // MARK: API

    struct LinkToken: Decodable { let linkToken: String; let expiration: String; let environment: String }

    func linkToken(country: String, connectionID: String? = nil, billAccess: Bool = false) async throws -> LinkToken {
        var body: [String: Any] = ["country": country]
        if let connectionID { body["connectionId"] = connectionID }
        if billAccess { body["billAccess"] = true }
        return try await request("POST", "/v1/link-token", body: body)
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

    func syncPage(connectionID: String, cursor: String?) async throws -> SyncPageResponse {
        try await request("POST", "/v1/connections/\(connectionID)/sync", body: ["cursor": cursor ?? NSNull()])
    }

    func creditCardBills(connectionID: String) async throws -> CreditCardBills {
        try await request("GET", "/v1/connections/\(connectionID)/credit-card-bills")
    }

    func disconnect(connectionID: String) async throws {
        struct R: Decodable { let status: String }
        let _: R = try await request("DELETE", "/v1/connections/\(connectionID)")
    }

    // MARK: Transport

    private func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil,
                                       base: URL? = nil, auth: Bool = true) async throws -> T {
        guard auth else { return try await send(method, path, body: body, base: base, bearer: nil) }
        do {
            return try await send(method, path, body: body, base: base, bearer: try await accessToken())
        } catch ServiceError.unauthorized {
            // The access token may have been revoked or the clock skewed: refresh once and retry.
            return try await send(method, path, body: body, base: base, bearer: try await accessToken(forceRefresh: true))
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
private actor AuthState {
    private var token: String?
    private var expiresAt = Date.distantPast
    private var inFlight: Task<String, Error>?

    func validToken() -> String? {
        guard let token, expiresAt.timeIntervalSinceNow > 60 else { return nil }
        return token
    }

    func set(token: String, expiresIn: Int) {
        self.token = token
        expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
    }

    func clear() { token = nil; expiresAt = .distantPast; inFlight?.cancel(); inFlight = nil }

    func refreshOnce(_ refresh: @escaping () async throws -> (String, Int)) async throws -> String {
        if let inFlight { return try await inFlight.value }
        let task = Task { () throws -> String in
            let (t, ttl) = try await refresh()
            self.set(token: t, expiresIn: ttl)
            return t
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
