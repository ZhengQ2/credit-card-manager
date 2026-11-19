import Foundation

struct SyncOutcome {
    var connectionID: String
    var result: Result<SyncApplyResult, Error>
}

/// Pulls /transactions/sync pages through the owner service (design §7).
/// - Serialized per connection (one in flight at a time).
/// - Pages are staged in memory from the last committed cursor; the batch and new cursor commit atomically.
/// - A pagination mutation discards staging and replays from the original cursor.
@MainActor
final class SyncEngine {
    private let client: ServiceClient
    private let repo: LedgerRepository
    private var inFlight: Set<String> = []

    init(client: ServiceClient, repo: LedgerRepository) {
        self.client = client
        self.repo = repo
    }

    func syncAll() async -> [SyncOutcome] {
        let env = client.environment
        let conns = ((try? repo.connections()) ?? []).filter {
            ($0.status == "active" || $0.status == "login_required") && (env == nil || $0.environment == env)
        }
        var out: [SyncOutcome] = []
        for c in conns where !inFlight.contains(c.id) {
            // Only sync once at least one account is mapped; unmapped rows are never persisted.
            let mapped = ((try? repo.accounts(connection: c.id)) ?? []).contains { $0.cardID != nil }
            guard mapped else { continue }
            out.append(SyncOutcome(connectionID: c.id, result: await sync(c.id)))
        }
        return out
    }

    func sync(_ connectionID: String) async -> Result<SyncApplyResult, Error> {
        guard !inFlight.contains(connectionID) else { return .success(SyncApplyResult()) }
        inFlight.insert(connectionID)
        defer { inFlight.remove(connectionID) }

        do {
            let committed = try repo.connection(connectionID)?.cursor
            var attempt = 0
            while true {
                attempt += 1
                var batch = SyncBatch()
                var cursor = committed
                var restart = false
                pages: while true {
                    let page = try await withBackoff { try await self.client.syncPage(connectionID: connectionID, cursor: cursor) }
                    switch page.status {
                    case "resync_required":
                        restart = true
                        break pages
                    case "not_ready":
                        throw ServiceError.notReady
                    default:
                        batch.added += page.added ?? []
                        batch.modified += page.modified ?? []
                        batch.removed += page.removed ?? []
                        batch.historyStatus = page.historyStatus
                        cursor = page.nextCursor
                        if page.hasMore != true { break pages }
                    }
                }
                if restart {
                    guard attempt < 4 else { throw ServiceError.server(code: "pagination_kept_mutating", retryable: true) }
                    continue // discard staging, replay from the committed cursor
                }
                let result = try repo.apply(batch, connection: connectionID, cursor: cursor ?? committed ?? "")
                if (try? repo.connection(connectionID))?.status == "login_required" {
                    try? repo.setStatus("active", connection: connectionID)
                }
                return .success(result)
            }
        } catch ServiceError.server(let code, _) where code == "connection_not_found" || code == "connection_disconnected" {
            // The service no longer knows this Item (e.g. it belongs to another Plaid environment). Stop syncing it;
            // local history stays.
            try? repo.closeConnection(connectionID)
            return .failure(ServiceError.server(code: "This bank connection is no longer available on your service. Its history is kept.", retryable: false))
        } catch ServiceError.loginRequired {
            try? repo.setStatus("login_required", connection: connectionID)
            return .failure(ServiceError.loginRequired)
        } catch {
            return .failure(error)
        }
    }

    /// Retries network, rate-limit and other retryable failures with exponential backoff.
    private func withBackoff<T>(_ op: () async throws -> T) async throws -> T {
        var delay: Double = 0.5
        for attempt in 1...4 {
            do { return try await op() }
            catch let e as ServiceError where e.isRetryable && e != .notReady && attempt < 4 {
                try await Task.sleep(for: .seconds(delay))
                delay *= 3
            }
        }
        return try await op()
    }
}
