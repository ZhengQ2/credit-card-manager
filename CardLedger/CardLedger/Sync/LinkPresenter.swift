import UIKit
import LinkKit

/// Presents Plaid Link with UIKit and keeps the LinkKit handler alive for the whole session.
///
/// LinkKit dismisses its own view controller when the user finishes or exits. Tearing down the SwiftUI
/// view that hosts Link (or presenting another sheet) during that dismissal makes LinkKit touch a
/// deallocating controller and crash. So results are delivered only after Link's dismissal has completed,
/// and the handler is released last.
@MainActor
final class LinkPresenter {
    private var handler: Handler?
    private weak var presenter: UIViewController?
    private var finished = false

    var isActive: Bool { handler != nil }

    func open(token: String, onSuccess: @escaping (String) -> Void, onExit: @escaping (String?) -> Void) {
        guard handler == nil else { return }
        finished = false
        var config = LinkTokenConfiguration(token: token) { [weak self] success in
            let publicToken = success.publicToken
            self?.deliver { onSuccess(publicToken) }
        }
        config.onExit = { [weak self] exit in
            let message = exit.error.map { "Plaid Link closed: \($0.localizedDescription)" }
            self?.deliver { onExit(message) }
        }
        switch Plaid.create(config) {
        case .success(let h):
            guard let presenter = Self.topViewController() else {
                onExit("Plaid Link could not be presented.")
                return
            }
            self.presenter = presenter
            handler = h
            h.open(presentUsing: .viewController(presenter))
        case .failure(let error):
            onExit("Plaid Link could not start: \(error)")
        }
    }

    private func deliver(_ action: @escaping () -> Void) {
        guard !finished else { return }
        finished = true
        Task { @MainActor [weak self] in
            // Wait until LinkKit's own view controller (including any OAuth Safari/nav controller) is fully off screen.
            for _ in 0..<40 {
                guard let self else { return }
                if self.presenter?.presentedViewController == nil && !Self.isLinkOnScreen() { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(250))
            action()
            self?.handler = nil
            self?.presenter = nil
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
    }

    static func topViewController() -> UIViewController? {
        var vc = keyWindow()?.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }

    private static func isLinkOnScreen() -> Bool {
        var vc = keyWindow()?.rootViewController
        while let next = vc?.presentedViewController {
            if String(reflecting: type(of: next)).hasPrefix("LinkKit.") { return true }
            vc = next
        }
        return false
    }
}
