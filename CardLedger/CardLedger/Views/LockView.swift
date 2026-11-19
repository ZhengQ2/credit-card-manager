import SwiftUI
import LocalAuthentication
import UIKit

/// Device-authentication lock (design §6) plus a privacy cover hosted in a dedicated overlay UIWindow so
/// balances and open sheets never appear in the app switcher or remain interactive while locked.
struct LockGate<Content: View>: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var unlocked = false
    @State private var isAuthenticating = false
    @State private var needsPrompt = true
    @State private var error: String?
    @ViewBuilder let content: Content

    private var showPrivacyCover: Bool { phase != .active }
    private var showLockScreen: Bool { phase == .active && store.requireDeviceAuth && !unlocked }
    private var canSync: Bool { phase == .active && (!store.requireDeviceAuth || unlocked) }

    var body: some View {
        content
            .background {
                WindowOverlayBridge(
                    isPresented: showPrivacyCover || showLockScreen,
                    overlay: LockOverlayContent(
                        isPrivacyCover: showPrivacyCover,
                        error: error,
                        onUnlock: authenticate
                    )
                )
            }
            .onChange(of: phase) { _, new in
                if new == .background {
                    unlocked = false
                    needsPrompt = true
                    error = nil
                } else if new == .active {
                    promptIfNeeded()
                }
            }
            .onChange(of: store.requireDeviceAuth) { _, required in
                if required {
                    unlocked = true // owner just toggled it on while already inside the app
                    needsPrompt = false
                } else {
                    error = nil
                }
            }
            .task(id: canSync) {
                if canSync { await store.syncIfStale() }
            }
            .onAppear {
                promptIfNeeded()
            }
    }

    private func promptIfNeeded() {
        guard phase == .active, store.requireDeviceAuth, !unlocked, needsPrompt, !isAuthenticating else { return }
        authenticate()
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            needsPrompt = false
            error = "Set a device passcode to use the lock."
            return
        }
        isAuthenticating = true
        needsPrompt = false
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your card ledger") { ok, e in
            Task { @MainActor in
                isAuthenticating = false
                unlocked = ok
                error = ok ? nil : e?.localizedDescription
            }
        }
    }
}

private struct LockOverlayContent: View {
    let isPrivacyCover: Bool
    let error: String?
    let onUnlock: () -> Void

    var body: some View {
        if isPrivacyCover {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
                .overlay { Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary) }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield").font(.system(size: 56)).foregroundStyle(.tint)
                Text("Card Ledger is locked").font(.title2.weight(.semibold))
                if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
                unlockButton
            }
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Color(.systemBackground).ignoresSafeArea() }
        }
    }

    @ViewBuilder
    private var unlockButton: some View {
        let button = Button("Unlock", action: onUnlock)
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }
}

/// Hosts an overlay SwiftUI view in a separate `UIWindow` above all presented sheets and alerts.
private struct WindowOverlayBridge<Overlay: View>: UIViewRepresentable {
    let isPresented: Bool
    let overlay: Overlay

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(scene: uiView.window?.windowScene, isPresented: isPresented, overlay: overlay)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        private var window: UIWindow?
        private var hosting: UIHostingController<Overlay>?

        func update(scene: UIWindowScene?, isPresented: Bool, overlay: Overlay) {
            guard isPresented else {
                teardown()
                return
            }
            let targetScene = scene ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            guard let targetScene else { return }
            if let hosting {
                hosting.rootView = overlay
                window?.isHidden = false
            } else {
                let hc = UIHostingController(rootView: overlay)
                hc.view.backgroundColor = .clear
                let w = UIWindow(windowScene: targetScene)
                w.windowLevel = .alert + 1
                w.rootViewController = hc
                w.isHidden = false
                self.hosting = hc
                self.window = w
            }
        }

        func teardown() {
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
            hosting = nil
        }
    }
}
