import SwiftUI

@main
struct CardLedgerApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store

    var body: some View {
        LockGate {
            adaptiveTabs
                .sheet(item: Binding(get: { store.pendingMappingConnectionID.map(IdentifiedString.init) },
                                     set: { store.pendingMappingConnectionID = $0?.id })) { MapAccountsView(connectionID: $0.id) }
                .sheet(item: Binding(get: { store.reauthConnectionID.map(IdentifiedString.init) },
                                     set: { store.reauthConnectionID = $0?.id })) { ReauthView(connectionID: $0.id) }
        }
    }

    @ViewBuilder
    private var adaptiveTabs: some View {
        if #available(iOS 27.0, *) {
            tabs
                .tabViewStyle(.sidebarAdaptable)
                .defaultTabBarPlacement(.sidebar)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        @Bindable var store = store
        return TabView(selection: $store.selectedTab) {
            Tab("Overview", systemImage: "calendar.badge.clock", value: Store.Tab.overview) { OverviewView() }
                .badge(store.openReviews.count)
            Tab("Cards", systemImage: "creditcard", value: Store.Tab.cards) { CardsView() }
            Tab("Activity", systemImage: "list.bullet.rectangle", value: Store.Tab.activity) { ActivityView() }
            Tab("Spending", systemImage: "chart.bar", value: Store.Tab.spending) { SpendingView() }
            Tab("Best Card", systemImage: "scope", value: Store.Tab.bestCard) { BestCardView() }
        }
    }
}

struct IdentifiedString: Identifiable {
    let id: String
}
