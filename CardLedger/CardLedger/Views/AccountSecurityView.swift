import AuthenticationServices
import CoreImage.CIFilterBuiltins
import SwiftUI

struct AccountSecurityView: View {
    @SwiftUI.Environment(Store.self) private var store
    @SwiftUI.Environment(\.authorizationController) private var authorizationController
    @State private var status: ServiceClient.SecurityStatus?
    @State private var setup: ServiceClient.TOTPSetup?
    @State private var setupCode = ""
    @State private var recoveryCodes: [String] = []
    @State private var editingPassword = false
    @State private var password = ""
    @State private var confirmedPassword = ""
    @State private var pendingRemoval: Removal?
    @State private var working = false
    @State private var error: String?

    private enum Removal: Equatable {
        case authenticator, password, passkey(String)

        var title: String {
            switch self {
            case .authenticator: "Turn off two-factor authentication?"
            case .password: "Remove your password?"
            case .passkey: "Remove this passkey?"
            }
        }

        var action: String {
            switch self {
            case .authenticator: "Turn off"
            case .password: "Remove password"
            case .passkey: "Remove passkey"
            }
        }
    }

    var body: some View {
        Form {
            if !recoveryCodes.isEmpty { recoverySection }
            if let status {
                passwordSection(enabled: status.passwordEnabled)
                authenticatorSection(enabled: status.totpEnabled)
                passkeySection(status)
            } else if !working {
                Button("Reload") { Task { await perform { try await loadStatus() } } }
            }
            if working { ProgressView().accessibilityLabel("Updating sign-in security") }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        }
        .navigationTitle("Sign-in security")
        .navigationBarTitleDisplayMode(.inline)
        .task { await perform { try await loadStatus() } }
        .confirmationDialog(pendingRemoval?.title ?? "Remove sign-in method?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { removal in
            Button(removal.action, role: .destructive) {
                Task { await remove(removal) }
            }
        } message: { removal in
            switch removal {
            case .authenticator: Text("Email and password sign-in will use one step. Your recovery codes will stop working.")
            case .password: Text("You can still sign in with an email code or an enrolled passkey.")
            case .passkey: Text("This passkey will stop signing in to your Card Ledger account.")
            }
        }
    }

    private func passwordSection(enabled: Bool) -> some View {
        Section {
            if editingPassword {
                SecureField("New password", text: $password).textContentType(.newPassword)
                SecureField("Confirm password", text: $confirmedPassword).textContentType(.newPassword)
                if !confirmedPassword.isEmpty && password != confirmedPassword {
                    Text("The passwords differ.").foregroundStyle(.secondary)
                }
                Button("Save password") { Task { await savePassword() } }
                    .disabled(working || password.unicodeScalars.count < 15 || password != confirmedPassword)
                Button("Cancel") { cancelPasswordEdit(); error = nil }.disabled(working)
            } else {
                Button(enabled ? "Change password" : "Set up a password") { editingPassword = true }.disabled(working)
                if enabled {
                    Button("Remove password…", role: .destructive) { pendingRemoval = .password }.disabled(working)
                }
            }
        } header: {
            Text("Password")
        } footer: {
            Text(editingPassword ? "Use 15 to 128 characters. The service keeps a password hash to verify future sign-ins."
                                  : "Add a password to sign in without waiting for an email code.")
        }
    }

    private func authenticatorSection(enabled: Bool) -> some View {
        Section {
            LabeledContent("Authenticator app", value: enabled ? "On" : "Off")
            if let setup {
                if let image = Self.qrImage(for: setup.uri) {
                    Image(uiImage: image)
                        .interpolation(.none).resizable().scaledToFit().frame(width: 192, height: 192)
                        .padding(12).background(.white).frame(maxWidth: .infinity)
                        .accessibilityLabel("Authenticator setup QR code").privacySensitive()
                }
                LabeledContent("Setup key") {
                    Text(setup.secret).font(.callout.monospaced()).textSelection(.enabled).privacySensitive()
                }
                TextField("6-digit authenticator code", text: $setupCode)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .onChange(of: setupCode) { _, value in
                        let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                        if value != digits { setupCode = digits }
                    }
                Button("Verify and turn on") { Task { await enable(setup) } }
                    .disabled(working || setupCode.count != 6)
                Button("Cancel setup") { cancelSetup(); error = nil }.disabled(working)
            } else if enabled {
                Button("Turn off two-factor authentication…", role: .destructive) { pendingRemoval = .authenticator }
                    .disabled(working || !recoveryCodes.isEmpty)
            } else {
                Button("Set up authenticator app") {
                    Task { await perform { setup = try await store.client.startTOTP() } }
                }.disabled(working)
            }
        } header: {
            Text("Two-factor authentication")
        } footer: {
            if setup != nil {
                Text("Scan the QR code or enter the setup key in your authenticator app. Then enter the current 6-digit code.")
            } else {
                Text("With an authenticator set up, email and password sign-in also require a code from the app. Skipping setup leaves one-step sign-in on.")
            }
        }
    }

    private func passkeySection(_ status: ServiceClient.SecurityStatus) -> some View {
        Section {
            ForEach(status.passkeys) { passkey in
                LabeledContent {
                    Button("Remove", role: .destructive) { pendingRemoval = .passkey(passkey.id) }
                        .disabled(working)
                } label: {
                    if let date = try? Date(passkey.createdAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                        Text("Added \(date.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Passkey")
                    }
                }
            }
            if status.passkeysEnabled && AccountPasskeys.isAvailable(for: store.serviceSession?.baseURL) {
                Button("Add a passkey", systemImage: "person.badge.key") { Task { await addPasskey() } }.disabled(working)
            } else {
                Text("Passkey setup is unavailable for this service or app build.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Passkeys")
        } footer: {
            Text("A passkey uses Face ID, Touch ID, or your device passcode. Card Ledger keeps the public key to verify sign-in. Without a saved passkey, use email or password sign-in.")
        }
    }

    private var recoverySection: some View {
        Section {
            Text("Save these codes somewhere you can reach without your authenticator. Each code works once and this screen shows them only now.")
            Text(recoveryCodes.joined(separator: "\n"))
                .font(.body.monospaced()).textSelection(.enabled).privacySensitive()
            Button("Done") { recoveryCodes = [] }
        } header: {
            Text("Recovery codes")
        }
    }

    private func loadStatus() async throws { status = try await store.client.securityStatus() }

    private func perform(_ action: () async throws -> Void) async {
        guard !working else { return }
        working = true
        error = nil
        defer { working = false }
        do { try await action() }
        catch is CancellationError { }
        catch let error as ASAuthorizationError where error.code == .canceled { }
        catch { self.error = accountAuthMessage(for: error) }
    }

    private func cancelSetup() {
        setup = nil
        setupCode = ""
    }

    private func cancelPasswordEdit() {
        password = ""
        confirmedPassword = ""
        editingPassword = false
    }

    private func savePassword() async {
        await perform {
            try await store.client.setPassword(password)
            cancelPasswordEdit()
            cancelSetup()
            store.updateAccountSession()
            try await loadStatus()
        }
    }

    private func enable(_ setup: ServiceClient.TOTPSetup) async {
        await perform {
            recoveryCodes = try await store.client.enableTOTP(id: setup.id, code: setupCode)
            cancelSetup()
            store.updateAccountSession()
            try await loadStatus()
        }
    }

    private func addPasskey() async {
        guard let url = store.serviceSession?.baseURL else { return }
        await perform {
            let options = try await store.client.startPasskeyRegistration()
            let credential = try await AccountPasskeys.registration(options, for: url, using: authorizationController)
            status = try await store.client.registerPasskey(id: options.id, credential: credential)
        }
    }

    private func remove(_ removal: Removal) async {
        await perform {
            switch removal {
            case .authenticator: try await store.client.disableTOTP()
            case .password: try await store.client.removePassword()
            case .passkey(let id): try await store.client.removePasskey(id: id)
            }
            cancelSetup()
            store.updateAccountSession()
            try await loadStatus()
        }
    }

    private static func qrImage(for uri: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(uri.utf8)
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

func accountAuthMessage(for error: Error) -> String {
    if let auth = error as? ASAuthorizationError {
        switch auth.code {
        case .matchedExcludedCredential: return "That passkey is already on your account."
        case .failed, .notHandled: return "Your device could not use a passkey for Card Ledger. Check your passkey settings and try again."
        default: break
        }
    }
    guard let service = error as? ServiceError, case .server(let code, _) = service else { return error.localizedDescription }
    switch code {
    case "code_invalid_or_expired": return "That email code is incorrect or has expired. You can request a new one."
    case "invite_required": return "Card Ledger is invite-only during testing. Ask for an invitation for this email address."
    case "code_locked": return "Too many incorrect codes. Request a new email code to continue."
    case "totp_invalid": return "That code is incorrect or has already been used. Try a new code."
    case "password_invalid": return "That email and password combination didn’t work. You can also sign in with an email code."
    case "password_length": return "Use a password between 15 and 128 characters."
    case "password_weak": return "Choose a less predictable password."
    case "challenge_invalid_or_expired": return "This verification has expired. Start again to get a new code or prompt."
    case "recent_sign_in_required": return "Sign out and sign in again before changing sign-in security."
    case "security_changed": return "Your sign-in security changed during this request. Try again."
    case "passkeys_unavailable": return "Passkeys are unavailable for this service or app build."
    case "passkey_invalid": return "Card Ledger could not verify that passkey. Try again or sign in by email."
    case "passkey_already_registered": return "That passkey is already on your account."
    case "passkey_limit": return "Remove a passkey before adding another."
    case "not_found": return "Update the Card Ledger service to manage sign-in security."
    default: return error.localizedDescription
    }
}
