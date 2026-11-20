import Foundation

/// Owner-logged use of an in-app credit or of a statement credit without a bank feed.
struct UsageLog: Identifiable, Hashable {
    let id: String
    let periodID: String
    let amount: Money
    let usedOn: Date
    let note: String
}

/// A free-night (or similar) certificate sitting in the owner's loyalty account.
struct AwardCertificate: Identifiable, Hashable {
    let id: String
    let cardID: String
    let ruleID: String
    var issuedOn: Date
    var expiresOn: Date
    var redeemedOn: Date?
    var note: String

    enum State: String { case available = "Available", redeemed = "Redeemed", expired = "Expired" }

    func state(today: Date) -> State {
        if redeemedOn != nil { return .redeemed }
        return today >= expiresOn ? .expired : .available
    }

    /// Last day the certificate can be used.
    var lastDay: Date { Day.add(-1, to: expiresOn) }
}

/// What the app knows and expects for one certificate benefit on one card.
struct CertificateStatus: Identifiable, Hashable {
    var id: String { "\(rule.id)|\(card.id)" }
    let card: Card
    let rule: BenefitRule
    let spec: CertificateSpec
    let certificates: [AwardCertificate]
    /// Calendar-year spend toward a spend-triggered award (net purchases on this card).
    let spend: Money?
    let threshold: Money?
    /// Window in which the next certificate should appear in the loyalty account.
    let expectedFrom: Date?
    let expectedBy: Date?
    /// True when an award is due (trigger has happened) but none has been recorded yet.
    let pending: Bool
    /// What the estimate is based on, e.g. "Annual fee posted Jan 12, 2026".
    let basis: String?
    let expectation: String

    /// Estimated expiry for the pending award (issue + validity).
    var estimatedExpiry: Date? { expectedBy.map { Day.addMonths(spec.validMonths, to: $0) } }
}

enum NonCreditEngine {
    static func certificateStatuses(card: Card, renewal: RenewalDate?, certificates: [AwardCertificate],
                                    transactions: [Transaction], today: Date) -> [CertificateStatus] {
        let product = Catalog.product(card.productID)
        let mineAll = transactions.filter { $0.cardID == card.id && !$0.pending }
        return product.benefits.compactMap { rule -> CertificateStatus? in
            guard rule.redemption == .certificate, let spec = rule.certificate else { return nil }
            let mine = certificates.filter { $0.cardID == card.id && $0.ruleID == rule.id }
                .sorted { $0.issuedOn > $1.issuedOn }
            switch spec.trigger {
            case .renewal:
                return renewalStatus(card: card, rule: rule, spec: spec, certs: mine, renewal: renewal, txs: mineAll, today: today)
            case .calendarYearSpend(let threshold):
                return spendStatus(card: card, rule: rule, spec: spec, certs: mine, threshold: threshold, txs: mineAll, today: today)
            }
        }
    }

    /// Picks the best renewal anchor: a posted annual fee (exact day), then a known renewal date, then the
    /// anniversary of the open date (estimated when the open date is only the start of history).
    private static func renewalAnchor(card: Card, renewal: RenewalDate?, txs: [Transaction], today: Date) -> (Date, String)? {
        let fee = txs.filter {
            $0.kind == .fee && $0.amount.minor > 0 && $0.posted <= today && $0.posted > Day.addMonths(-13, to: today)
                && PlaidMapping.isAnnualFee($0.originalDescription.uppercased())
        }.max { $0.posted < $1.posted }
        if let fee { return (fee.posted, "Annual fee posted \(Day.format(fee.posted))") }
        if let renewal {
            let precision = renewal.precision == .month ? " (month only)" : ""
            return (renewal.date, "Renewal \(Day.format(renewal.date))\(precision) · \(renewal.source.rawValue.lowercased())")
        }
        let note = card.openDateStatus == .confirmed ? "open date" : "estimated open date (start of history)"
        guard card.openDateStatus != .older else { return nil }
        return (card.openedOn, "Anniversary of \(note) \(Day.format(card.openedOn))")
    }

    private static func renewalStatus(card: Card, rule: BenefitRule, spec: CertificateSpec, certs: [AwardCertificate],
                                      renewal: RenewalDate?, txs: [Transaction], today: Date) -> CertificateStatus {
        let lag = spec.issueLagWeeks * 7
        guard let (base, basis) = renewalAnchor(card: card, renewal: renewal, txs: txs, today: today) else {
            return CertificateStatus(card: card, rule: rule, spec: spec, certificates: certs, spend: nil, threshold: nil,
                                     expectedFrom: nil, expectedBy: nil, pending: false, basis: nil,
                                     expectation: "Issued after each renewal. Set the open or renewal date to estimate it.")
        }
        // Awards follow renewals, never the opening day itself.
        let firstEligible = Day.add(300, to: card.openedOn)
        var anchor = base
        while anchor > today { anchor = Day.addMonths(-12, to: anchor) }   // most recent anchor on or before today
        while Day.addMonths(12, to: anchor) <= today { anchor = Day.addMonths(12, to: anchor) }
        let recorded = certs.contains { $0.issuedOn >= Day.add(-30, to: anchor) }
        // An unrecorded award from the latest renewal is still worth flagging until it would have expired.
        let likelyExpiry = Day.addMonths(spec.validMonths, to: anchor)
        let due = anchor >= firstEligible && !recorded && today < likelyExpiry
        let trigger = due ? anchor : {
            var next = Day.addMonths(12, to: anchor)
            while next < firstEligible { next = Day.addMonths(12, to: next) }
            return next
        }()
        let from = trigger, by = Day.add(lag, to: trigger)
        let text: String
        if due && today > by {
            let expFrom = Day.addMonths(spec.validMonths, to: from), expBy = Day.addMonths(spec.validMonths, to: by)
            text = "Probably in your loyalty account since \(Day.format(from, .dateTime.month(.abbreviated).year())) "
                + "(after your renewal). Likely expires \(Day.format(expFrom, .dateTime.month(.abbreviated).day())) – \(Day.format(expBy)). Record it to track it."
        } else if due {
            text = "Due now: should post between \(Day.format(from, .dateTime.month(.abbreviated).day())) and \(Day.format(by))."
        } else {
            text = "Next expected \(Day.format(from, .dateTime.month(.abbreviated).day())) – \(Day.format(by)), after your renewal."
        }
        return CertificateStatus(card: card, rule: rule, spec: spec, certificates: certs, spend: nil, threshold: nil,
                                 expectedFrom: from, expectedBy: by, pending: due, basis: basis, expectation: text)
    }

    private static func spendStatus(card: Card, rule: BenefitRule, spec: CertificateSpec, certs: [AwardCertificate],
                                    threshold: Money, txs: [Transaction], today: Date) -> CertificateStatus {
        let lag = spec.issueLagWeeks * 7
        let year = Day.ymd(today).y
        let start = Day.make(year, 1, 1)
        let yearTxs = txs.filter {
            $0.posted >= start && $0.posted <= today && $0.amount.currency == threshold.currency
                && ($0.kind == .purchase || $0.kind == .refund)
        }.sorted { $0.posted < $1.posted }
        // A refund can reset the qualifying date until net spend reaches the threshold again.
        var running = 0
        var crossed: Date?
        for t in yearTxs {
            running += t.amount.minor
            if running < threshold.minor {
                crossed = nil
            } else if crossed == nil {
                crossed = t.posted
            }
        }
        let spend = Money(max(0, running), threshold.currency)
        let earnedThisYear = certs.contains { Day.ymd($0.issuedOn).y == year }
        let basis = "Posted purchases minus refunds on this card since Jan 1"

        if earnedThisYear {
            return CertificateStatus(card: card, rule: rule, spec: spec, certificates: certs, spend: spend, threshold: threshold,
                                     expectedFrom: nil, expectedBy: nil, pending: false, basis: basis,
                                     expectation: "Earned for \(year). Spend resets on Jan 1.")
        }
        if let crossed {
            let by = Day.add(lag, to: crossed)
            let text = today > by
                ? "Spend met \(Day.format(crossed)). Overdue: expected by \(Day.format(by)); check your loyalty account."
                : "Spend met \(Day.format(crossed)). Should post by \(Day.format(by))."
            return CertificateStatus(card: card, rule: rule, spec: spec, certificates: certs, spend: spend, threshold: threshold,
                                     expectedFrom: crossed, expectedBy: by, pending: true, basis: basis, expectation: text)
        }
        // Project the crossing date from this year's pace.
        let elapsed = max(1, Day.days(from: start, to: today))
        let left = threshold.minor - spend.minor
        var text = "\(Money(left, threshold.currency).short) more spend in \(year) earns it."
        var from: Date?, by: Date?
        if spend.minor > 0 {
            let remainingDaysInYear = max(0, Day.days(from: today, to: Day.make(year, 12, 31)))
            let rawDaysNeeded = (Double(left) / (Double(spend.minor) / Double(elapsed))).rounded(.up)
            if rawDaysNeeded.isFinite && rawDaysNeeded <= Double(remainingDaysInYear) {
                let projected = Day.add(Int(rawDaysNeeded), to: today)
                from = projected; by = Day.add(lag, to: projected)
                text += " At your current pace you'd reach it around \(Day.format(projected, .dateTime.month(.abbreviated).day()))."
            } else {
                text += " At your current pace you won't reach it this year."
            }
        }
        return CertificateStatus(card: card, rule: rule, spec: spec, certificates: certs, spend: spend, threshold: threshold,
                                 expectedFrom: from, expectedBy: by, pending: false, basis: basis, expectation: text)
    }
}
