import Foundation

struct BillReport: Codable {
    let serviceURL: URL
    let fetchedAt: Date
    let response: CreditCardBills
}

extension Store {
    var billConnections: [StoredConnection] {
        guard mode == .live, let pairing, let repo else { return [] }
        let mapped = Set(cards.compactMap(\.connectionID))
        return ((try? repo.connections()) ?? []).filter {
            mapped.contains($0.id) && $0.environment == pairing.environment
                && ($0.status == "active" || $0.status == "login_required")
        }
    }

    func billReport(for connectionID: String) -> BillReport? {
        guard let pairing, let report = billReports[connectionID], report.serviceURL == pairing.baseURL else { return nil }
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

    func setBillAlertsEnabled(_ enabled: Bool) async {
        guard let repo else {
            billRefreshMessage = "Encrypted storage is unavailable."
            return
        }
        if enabled {
            guard await billNotifications.requestAccess() else { return }
        }
        do { try repo.setSetting("bill_alerts_enabled", enabled ? "1" : nil) }
        catch {
            billRefreshMessage = "Couldn’t save your bill alert setting."
            return
        }
        billAlertsEnabled = enabled
        billRefreshMessage = nil
        if enabled { Task { await refreshBillAlerts(force: true) } }
        else {
            needsBillRefresh = false
            updateBillNotifications()
        }
    }

    func refreshBillAlerts(force: Bool = false) async {
        if isRefreshingBills {
            if force { needsBillRefresh = true }
            return
        }
        updateBillNotifications()
        guard billAlertsEnabled, let pairing, let repo else { return }
        let connections = billConnections.filter { connection in
            guard connection.status == "active" else { return false }
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

        for connection in connections {
            guard !Task.isCancelled, self.pairing == pairing, billAlertsEnabled else { return }
            do {
                let response = try await client.creditCardBills(connectionID: connection.id)
                guard !Task.isCancelled, self.pairing == pairing, billAlertsEnabled else { return }
                guard let current = try repo.connection(connection.id), current.status == "active" else { continue }
                let mapped = Set(try repo.accounts(connection: connection.id).filter { $0.cardID != nil }.map(\.id))
                let saved = CreditCardBills(status: response.status, bills: response.bills.filter { mapped.contains($0.accountId) })
                let report = BillReport(serviceURL: pairing.baseURL, fetchedAt: Date(), response: saved)
                try repo.saveBillReport(report, connectionID: connection.id)
                billReports[connection.id] = report
            } catch is CancellationError {
                return
            } catch {
                guard self.pairing == pairing, billAlertsEnabled else { return }
                switch error {
                case ServiceError.unauthorized:
                    for affected in billConnections { removeBillReport(connectionID: affected.id) }
                    billRefreshMessage = error.localizedDescription
                    return
                case ServiceError.loginRequired:
                    try? repo.setStatus("login_required", connection: connection.id)
                    reload()
                case ServiceError.server(let code, _) where code == "not_found":
                    billRefreshMessage = "Update the owner service to use bill payment alerts."
                    return
                case ServiceError.server(let code, _) where ["connection_not_found", "connection_disconnected", "ITEM_NOT_FOUND"].contains(code):
                    removeBillReport(connectionID: connection.id)
                    billRefreshMessage = "A bank connection is no longer available on the owner service."
                default:
                    billRefreshMessage = "Couldn’t refresh all payment dates. Previously synced dates are kept."
                }
            }
        }
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
