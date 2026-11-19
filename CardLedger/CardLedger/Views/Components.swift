import SwiftUI

extension CardStyle {
    var gradient: LinearGradient {
        LinearGradient(colors: [backgroundColor(from), backgroundColor(to)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var foreground: Color { lightText ? .white : .black }

    private func backgroundColor(_ hex: String) -> Color {
        let v = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x808080
        // Leave room for the pattern while keeping the foreground readable over the gradient.
        func channel(_ shift: Int) -> Double {
            let value = Double((v >> shift) & 0xFF) / 255
            return lightText ? value * 0.60 : 0.28 + value * 0.72
        }
        return Color(red: channel(16), green: channel(8), blue: channel(0))
    }
}

struct CardChip: View {
    let card: Card
    var size: CGFloat = 36

    var body: some View {
        CardThumbnail(product: Catalog.product(card.productID), height: size)
    }
}

struct CardThumbnail: View {
    let product: CardProduct
    var height: CGFloat = 24

    var body: some View {
        Text(product.artCode)
            .font(.system(size: max(8, height * 0.32), weight: .bold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(product.color.foreground)
            .padding(.horizontal, height * 0.08)
            .frame(width: height * 1.58, height: height)
            .background {
                CardArtBackground(product: product, cornerRadius: height * 0.19)
            }
            .accessibilityHidden(true)
    }
}

/// SwiftUI-drawn geometry shared across wallet cards, thumbnails and the catalog picker.
private struct CardArtBackground: View {
    let product: CardProduct
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let ink = product.color.foreground
        ZStack {
            shape.fill(product.color.gradient)
            Canvas { context, size in
                let step = size.height * 0.11
                // The open side of the pattern distinguishes the two markets.
                let origin = product.market == .cad ? size.width : 0
                let direction: CGFloat = product.market == .cad ? -1 : 1
                for index in 0..<4 {
                    let inset = CGFloat(index) * step
                    var path = Path()
                    path.move(to: CGPoint(x: origin + direction * (size.height * 0.72 + inset), y: 0))
                    path.addLine(to: CGPoint(x: origin + direction * inset, y: size.height * 0.72))
                    path.addLine(to: CGPoint(x: origin + direction * inset, y: size.height))
                    context.stroke(path, with: .color(ink.opacity(0.08)), lineWidth: max(0.6, step * 0.17))
                }
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(ink.opacity(0.17), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

struct CardArt: View {
    let card: Card

    var body: some View {
        let product = Catalog.product(card.productID)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(product.issuer).font(.subheadline.weight(.semibold))
                Spacer()
                Text(product.market.rawValue).font(.caption.weight(.bold).monospaced())
            }
            Spacer(minLength: 0)
            Text(product.artCode)
                .font(.largeTitle.weight(.heavy).monospaced())
                .accessibilityHidden(true)
            Text(product.name).font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let mask = card.mask {
                Text("•••• \(mask)").font(.callout.monospaced())
            }
        }
        .foregroundStyle(product.color.foreground)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 186, alignment: .leading)
        .background { CardArtBackground(product: product, cornerRadius: 18) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(product.displayName), \(product.market.rawValue), ending \(card.mask ?? "unknown")")
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let symbol { Image(systemName: symbol) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

extension EvidenceStatus {
    var color: Color {
        switch self {
        case .pendingPurchase: .gray
        case .awaitingCredit: .orange
        case .confirmed: .green
        case .needsReview: .purple
        case .notCredited: .red
        case .capReached: .secondary
        case .unmatched: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .pendingPurchase: "clock"
        case .awaitingCredit: "hourglass"
        case .confirmed: "checkmark.circle.fill"
        case .needsReview: "questionmark.circle.fill"
        case .notCredited: "exclamationmark.triangle.fill"
        case .capReached: "checkmark.circle"
        case .unmatched: "minus.circle"
        }
    }
}

extension BenefitPeriod.State {
    var color: Color {
        switch self {
        case .unused: .red
        case .awaiting: .orange
        case .partial: .blue
        case .full: .green
        }
    }
}

struct UsageBar: View {
    let period: BenefitPeriod

    var body: some View {
        let cap = Double(max(period.cap.minor, 1))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(Color.orange.opacity(0.55))
                    .frame(width: geo.size.width * min(1, Double(period.confirmed.minor + period.awaiting.minor) / cap))
                Capsule().fill(Color.green)
                    .frame(width: geo.size.width * min(1, Double(period.confirmed.minor) / cap))
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Used \(period.confirmed.formatted) of \(period.cap.formatted)")
        .accessibilityValue(period.awaiting.minor > 0 ? "\(period.awaiting.formatted) awaiting credit" : "")
    }
}

struct DaysLeftText: View {
    let days: Int

    var body: some View {
        Text(days == 0 ? "Ends today" : days == 1 ? "1 day left" : "\(days) days left")
            .font(.caption.weight(.semibold))
            .foregroundStyle(days <= 7 ? .red : days <= 14 ? .orange : .secondary)
    }
}

extension Date {
    var relativeAge: String {
        if abs(timeIntervalSinceNow) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: self, relativeTo: Date())
    }
}

extension Double {
    /// Minor units to a Money value.
    func money(_ c: CurrencyCode) -> Money { Money(Int(self.rounded()), c) }
}
