import Foundation

struct SyncOutcome {
    var connectionID: String
    var result: Result<SyncApplyResult, Error>
}

/// Pulls /transactions/sync pages through the Card Ledger API (design §7).
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
        let mappedConns = conns.filter { c in
            !inFlight.contains(c.id) && ((try? repo.accounts(connection: c.id)) ?? []).contains { $0.cardID != nil }
        }
        guard !mappedConns.isEmpty else { return [] }
        if !client.isSignedIn {
            return [SyncOutcome(connectionID: mappedConns[0].id, result: .failure(ServiceError.notSignedIn))]
        }
        var out: [SyncOutcome] = []
        for c in mappedConns {
            let result = await sync(c.id)
            out.append(SyncOutcome(connectionID: c.id, result: result))
            if case .failure(ServiceError.unauthorized) = result { break }
        }
        return out
    }

    func sync(_ connectionID: String) async -> Result<SyncApplyResult, Error> {
        guard !inFlight.contains(connectionID) else { return .success(SyncApplyResult()) }
        inFlight.insert(connectionID)
        defer { inFlight.remove(connectionID) }

        do {
            let accounts = try mappedAccounts(connectionID)
            guard !accounts.isEmpty else { return .success(SyncApplyResult()) }
            let raw = try repo.connection(connectionID)?.cursor
            // Old item-wide cursors do not apply to individual accounts. Replay each mapped card from its start.
            let committed = raw.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
            var cursors: [String: String] = [:]
            var batch = SyncBatch()
            for account in accounts {
                let staged = try await stage(connectionID: connectionID, accountID: account.id, committed: committed[account.id])
                batch.pages.append(contentsOf: staged.batch.pages)
                batch.historyStatus = staged.batch.historyStatus ?? batch.historyStatus
                cursors[account.id] = staged.cursor
            }
            let current = try mappedAccounts(connectionID)
            guard current.map(\.id) == accounts.map(\.id),
                  let connection = try repo.connection(connectionID), connection.status == "active" || connection.status == "login_required" else {
                return .success(SyncApplyResult())
            }
            let cursor = String(decoding: try JSONEncoder().encode(cursors), as: UTF8.self)
            let result = try repo.apply(batch, connection: connectionID, cursor: cursor)
            if connection.status == "login_required" { try? repo.setStatus("active", connection: connectionID) }
            return .success(result)
        } catch is CancellationError {
            return .success(SyncApplyResult())
        } catch ServiceError.server(let code, _) where code == "connection_not_found" || code == "connection_disconnected" || code == "ITEM_NOT_FOUND" {
            // The service or Plaid no longer knows this Item. Stop syncing it; local history stays.
            try? repo.closeConnection(connectionID)
            return .failure(ServiceError.server(code: "This bank connection is no longer available on your service. Its history is kept.", retryable: false))
        } catch ServiceError.loginRequired {
            try? repo.setStatus("login_required", connection: connectionID)
            return .failure(ServiceError.loginRequired)
        } catch {
            return .failure(error)
        }
    }

    private func mappedAccounts(_ connectionID: String) throws -> [SourceAccount] {
        try repo.accounts(connection: connectionID).filter { $0.isCreditCard && $0.cardID != nil }
    }

    private func stage(connectionID: String, accountID: String, committed: String?) async throws -> (batch: SyncBatch, cursor: String) {
        for _ in 0..<4 {
            var batch = SyncBatch()
            var cursor = committed
            pages: while true {
                let page = try await withBackoff {
                    guard try self.mappedAccounts(connectionID).contains(where: { $0.id == accountID }) else { throw CancellationError() }
                    return try await self.client.syncPage(connectionID: connectionID, accountID: accountID, cursor: cursor)
                }
                switch page.status {
                case "resync_required": break pages
                case "not_ready":
                    // Store.sync schedules a retry while Plaid prepares the card's history.
                    try? repo.setHistoryStatus("NOT_READY", connection: connectionID)
                    throw ServiceError.notReady
                default:
                    guard page.accountId == accountID, let next = page.nextCursor else {
                        throw ServiceError.server(code: "scoped_sync_required", retryable: false)
                    }
                    batch.pages.append(SyncPageDelta(added: page.added ?? [], modified: page.modified ?? [], removed: page.removed ?? []))
                    batch.historyStatus = page.historyStatus
                    cursor = next
                    if page.hasMore != true { return (batch, next) }
                }
            }
        }
        throw ServiceError.server(code: "pagination_kept_mutating", retryable: true)
    }

    /// Retries network, rate-limit and other retryable failures with exponential backoff.
    private func withBackoff<T>(_ op: () async throws -> T) async throws -> T {
        var delay: Double = 0.5
        for _ in 1..<4 {
            do { return try await op() }
            catch let e as ServiceError where e.isRetryable && e != .notReady {
                try await Task.sleep(for: .seconds(delay))
                delay *= 3
            }
        }
        return try await op()
    }
}
