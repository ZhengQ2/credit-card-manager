import SwiftUI
import LocalAuthentication

/// Device-authentication lock (design §6) plus a privacy cover so balances never appear in the app switcher.
struct LockGate<Content: View>: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var unlocked = false
    @State private var error: String?
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            content
            if phase != .active {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
                    .overlay { Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary) }
            } else if store.requireDeviceAuth && !unlocked {
                VStack(spacing: 16) {
                    Image(systemName: "lock.shield").font(.system(size: 56)).foregroundStyle(.tint)
                    Text("Card Ledger is locked").font(.title2.weight(.semibold))
                    if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
                    Button("Unlock") { authenticate() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                .onAppear(perform: authenticate)
            }
        }
        .onChange(of: phase) { _, new in
            if new == .background { unlocked = false }
            if new == .active { Task { await store.syncIfStale() } }
        }
    }

    private func authenticate() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            error = "Set a device passcode to use the lock."
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your card ledger") { ok, e in
            Task { @MainActor in
                unlocked = ok
                error = ok ? nil : e?.localizedDescription
            }
        }
    }
}
