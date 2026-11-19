import Foundation

enum ServiceError: Error, LocalizedError, Equatable {
    case notPaired
    case unreachable
    case tlsError(String)
    case unauthorized
    case loginRequired
    case notReady
    case rateLimited
    case server(code: String, retryable: Bool)

    var errorDescription: String? {
        switch self {
        case .notPaired: "Pair with your service in Settings first."
        case .unreachable: "Your service is offline or unreachable."
        case .tlsError(let detail): "Secure connection to your service failed: \(detail)"
        case .unauthorized: "This iPhone is no longer authorized. Pair again in Settings."
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

struct PairingConfig: Codable, Equatable {
    var baseURL: URL
    var deviceID: String
    var credential: String
    var environment: String
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

/// Talks to the owner service over the LAN/VPN (design §6–7). Ephemeral session: no URL cache, no cookies.
final class ServiceClient {
    private let session: URLSession
    private(set) var pairing: PairingConfig?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        if let data = Keychain.data(.serviceCredential) {
            pairing = try? JSONDecoder().decode(PairingConfig.self, from: data)
        }
    }

    var isPaired: Bool { pairing != nil }
    var environment: String? { pairing?.environment }

    // MARK: Pairing

    /// Verifies the service, redeems the one-time code, and stores the device credential in the Keychain.
    func pair(baseURL: URL, code: String, deviceName: String) async throws {
        struct Health: Decodable { let ok: Bool; let service: String; let environment: String }
        struct Paired: Decodable { let deviceId: String; let credential: String; let environment: String }
        let health: Health = try await request("GET", "/v1/health", base: baseURL, auth: false)
        guard health.ok, health.service == "card-ledger-owner-service" else { throw ServiceError.server(code: "not_a_card_ledger_service", retryable: false) }
        let paired: Paired = try await request("POST", "/v1/pair", body: ["code": code, "deviceName": deviceName], base: baseURL, auth: false)
        let cfg = PairingConfig(baseURL: baseURL, deviceID: paired.deviceId, credential: paired.credential, environment: paired.environment)
        guard Keychain.set(try JSONEncoder().encode(cfg), for: .serviceCredential) else {
            throw ServiceError.server(code: "keychain_save_failed", retryable: false)
        }
        pairing = cfg
    }

    func unpair() {
        Keychain.delete(.serviceCredential)
        pairing = nil
    }

    // MARK: API

    struct LinkToken: Decodable { let linkToken: String; let expiration: String; let environment: String }

    func linkToken(country: String, connectionID: String? = nil) async throws -> LinkToken {
        var body = ["country": country]
        if let connectionID { body["connectionId"] = connectionID }
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

    func disconnect(connectionID: String) async throws {
        struct R: Decodable { let status: String }
        let _: R = try await request("DELETE", "/v1/connections/\(connectionID)")
    }

    // MARK: Transport

    private func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil,
                                       base: URL? = nil, auth: Bool = true) async throws -> T {
        guard let baseURL = base ?? pairing?.baseURL else { throw ServiceError.notPaired }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = trimmed.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if auth {
            guard let p = pairing else { throw ServiceError.notPaired }
            req.setValue("Bearer \(p.deviceID).\(p.credential)", forHTTPHeaderField: "Authorization")
        }
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
        case (401, "unauthorized"): throw ServiceError.unauthorized
        case (409, "ITEM_LOGIN_REQUIRED"): throw ServiceError.loginRequired
        case (429, _): throw ServiceError.rateLimited
        default: throw ServiceError.server(code: err?.error ?? "http_\(status)", retryable: err?.retryable ?? (status >= 500))
        }
    }
}

private struct ServiceErrorBody: Decodable { let error: String; let retryable: Bool? }
