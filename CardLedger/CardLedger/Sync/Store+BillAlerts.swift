import Foundation

struct BillReport: Codable {
    let serviceURL: URL
    let accountUserID: String
    let fetchedAt: Date
    let response: CreditCardBills
}

extension Store {
    var needsBillAlertChoice: Bool {
        guard let session = serviceSession, let repo else { return false }
        return repo.setting("bill_alert_choice.\(session.userID)") == nil
    }

    var billConnections: [StoredConnection] {
        guard mode == .live, let serviceSession, let repo else { return [] }
        let mapped = Set(cards.compactMap(\.connectionID))
        return ((try? repo.connections()) ?? []).filter {
            mapped.contains($0.id) && $0.environment == serviceSession.environment
                && ($0.status == "active" || $0.status == "login_required")
        }
    }

    func billReport(for connectionID: String) -> BillReport? {
        guard !billWithdrawalPending(connectionID), let serviceSession, let report = billReports[connectionID], report.serviceURL == serviceSession.baseURL,
              report.accountUserID == serviceSession.userID else { return nil }
        return report
    }

    var upcomingCardBills: [BillPayment] {
        guard billAlertsEnabled, let repo else { return [] }
        let today = Day.today
        var dates: [String: Date] = [:]
        for connection in billConnections {
            guard let report = billReport(for: connection.id), report.response.status == .available,
                  let accounts = try? repo.accounts(connection: connection.id) else { continue }
            let mapped = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
                account.cardID.map { (account.id, $0) }
            })
            for bill in report.response.bills {
                guard let cardID = mapped[bill.accountId], let due = bill.day, due >= today else { continue }
                dates[cardID] = min(dates[cardID] ?? due, due)
            }
        }
        return dates.map { BillPayment(cardID: $0.key, dueDate: $0.value) }
            .sorted { ($0.dueDate, $0.cardID) < ($1.dueDate, $1.cardID) }
    }

    @discardableResult
    func setBillAlertsEnabled(_ enabled: Bool) async -> Bool {
        guard let repo, let accountID = serviceSession?.userID else {
            billRefreshMessage = "Sign in with encrypted storage available to save a bill alert preference."
            return false
        }
        if enabled {
            guard await billNotifications.requestAccess(), serviceSession?.userID == accountID else { return false }
        }
        do {
            try repo.db.transaction {
                try repo.setSetting("bill_alert_choice.\(accountID)", enabled ? "enabled" : "skipped")
                if !enabled { try repo.clearBillReports() }
            }
        }
        catch {
            billRefreshMessage = "Couldn’t save your bill alert setting."
            return false
        }
        billAlertsEnabled = enabled
        billRefreshMessage = nil
        if enabled { Task { await refreshBillAlerts(force: true) } }
        else {
            needsBillRefresh = false
            billReports.removeAll()
            updateBillNotifications()
        }
        return true
    }

    func refreshBillAlerts(force: Bool = false) async {
        if isRefreshingBills {
            if force { needsBillRefresh = true }
            return
        }
        updateBillNotifications()
        guard billAlertsEnabled, let serviceSession, let repo else { return }
        let connections = billConnections.filter { connection in
            guard connection.status == "active", !billWithdrawalPending(connection.id), !withdrawingBillAccess.contains(connection.id) else { return false }
            guard !force, let report = billReport(for: connection.id) else { return true }
            return Date().timeIntervalSince(report.fetchedAt) >= 4 * 3600
        }
        guard !connections.isEmpty else { return }

        isRefreshingBills = true
        billRefreshMessage = nil
        defer {
            isRefreshingBills = false
            updateBillNotifications()
            if needsBillRefresh {
                needsBillRefresh = false
                Task { await refreshBillAlerts(force: true) }
            }
        }

        let notificationAccess = await billNotifications.hasAccess()
        guard self.serviceSession == serviceSession, billAlertsEnabled else { return }
        guard notificationAccess else {
            try? repo.clearBillReports()
            billReports.removeAll()
            return
        }

        for connection in connections {
            guard !Task.isCancelled, self.serviceSession == serviceSession, billAlertsEnabled else { return }
            let revision = billAccessRevision[connection.id, default: 0]
            do {
                let requested = try repo.accounts(connection: connection.id).filter { $0.isCreditCard && $0.cardID != nil }.map(\.id)
                guard !requested.isEmpty, !withdrawingBillAccess.contains(connection.id), !billWithdrawalPending(connection.id) else { continue }
                let response = try await client.creditCardBills(connectionID: connection.id, accountIDs: requested)
                guard !Task.isCancelled, self.serviceSession == serviceSession, billAlertsEnabled else { return }
                guard revision == billAccessRevision[connection.id, default: 0] else { continue }
                guard let current = try repo.connection(connection.id), current.status == "active" else { continue }
                let mapped = Set(try repo.accounts(connection: connection.id).filter { $0.isCreditCard && $0.cardID != nil }.map(\.id))
                let saved = CreditCardBills(status: response.status, bills: response.bills.filter {
                    mapped.contains($0.accountId) && ($0.day ?? .distantPast) >= Day.today
                })
                let report = BillReport(serviceURL: serviceSession.baseURL, accountUserID: serviceSession.userID, fetchedAt: Date(), response: saved)
                try repo.saveBillReport(report, connectionID: connection.id)
                billReports[connection.id] = report
            } catch is CancellationError {
                return
            } catch {
                guard self.serviceSession == serviceSession, billAlertsEnabled else { return }
                switch error {
                case ServiceError.unauthorized:
                    for affected in billConnections { removeBillReport(connectionID: affected.id) }
                    billRefreshMessage = error.localizedDescription
                    return
                case ServiceError.loginRequired:
                    try? repo.setStatus("login_required", connection: connection.id)
                    reload()
                case ServiceError.server(let code, _) where code == "not_found":
                    billRefreshMessage = "The service doesn’t support bill payment alerts yet."
                    return
                case ServiceError.server(let code, _) where ["connection_not_found", "connection_disconnected", "ITEM_NOT_FOUND"].contains(code):
                    removeBillReport(connectionID: connection.id)
                    billRefreshMessage = "A bank connection is no longer available on the service."
                default:
                    billRefreshMessage = "Couldn’t refresh all payment dates. Previously synced dates are kept."
                }
            }
        }
    }

    func withdrawBillAccess(connectionID: String) async throws {
        guard let repo, let accountID = serviceSession?.userID else { throw ServiceError.notSignedIn }
        guard withdrawingBillAccess.insert(connectionID).inserted else { return }
        defer { withdrawingBillAccess.remove(connectionID) }
        billAccessRevision[connectionID, default: 0] += 1
        let key = "bill_withdrawal.\(connectionID)"
        try repo.db.transaction {
            try repo.setSetting(key, accountID)
            try repo.saveBillReport(nil, connectionID: connectionID)
        }
        billReports.removeValue(forKey: connectionID)
        updateBillNotifications()
        do { try await client.withdrawBillAccess(connectionID: connectionID) }
        catch ServiceError.server("connection_not_found", _) { }
        try repo.setSetting(key, nil)
    }

    func billWithdrawalPending(_ connectionID: String) -> Bool {
        guard let accountID = serviceSession?.userID else { return false }
        return repo?.setting("bill_withdrawal.\(connectionID)") == accountID
    }

    func removeBillReport(connectionID: String) {
        billReports.removeValue(forKey: connectionID)
        try? repo?.saveBillReport(nil, connectionID: connectionID)
        updateBillNotifications()
    }

    func updateBillNotifications() {
        billNotifications.update(upcomingCardBills, enabled: billAlertsEnabled)
    }
}
