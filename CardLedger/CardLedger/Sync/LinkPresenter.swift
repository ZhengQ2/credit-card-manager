import SwiftUI
import LinkKit

/// Keeps Link attached to the initiating view's sheet so it follows that window as the device resizes.
@MainActor
@Observable
final class LinkPresenter {
    private(set) var handler: Handler?
    var isPresented = false
    private var completion: (() -> Void)?

    func open(token: String, onSuccess: @escaping (String) -> Void, onExit: @escaping (String?) -> Void) {
        guard handler == nil else { return }
        var config = LinkTokenConfiguration(token: token) { [weak self] success in
            let publicToken = success.publicToken
            self?.finish { onSuccess(publicToken) }
        }
        config.onExit = { [weak self] exit in
            let message = exit.error.map { "Plaid Link closed: \($0.localizedDescription)" }
            self?.finish { onExit(message) }
        }
        switch Plaid.create(config) {
        case .success(let h):
            handler = h
            isPresented = true
        case .failure(let error):
            onExit("Plaid Link could not start: \(error)")
        }
    }

    private func finish(_ action: @escaping () -> Void) {
        guard handler != nil, completion == nil else { return }
        completion = action
        isPresented = false
    }

    func didDismiss() {
        // Linking can dismiss the parent form and open account mapping. Keep LinkKit alive until its sheet closes.
        let action = completion
        completion = nil
        handler = nil
        action?()
    }
}

extension View {
    @MainActor
    func plaidLinkSheet(_ presenter: LinkPresenter) -> some View {
        @Bindable var presenter = presenter
        return sheet(isPresented: $presenter.isPresented, onDismiss: presenter.didDismiss) {
            presenter.handler?.makePlaidLinkSheet()
                .interactiveDismissDisabled()
        }
    }
}
