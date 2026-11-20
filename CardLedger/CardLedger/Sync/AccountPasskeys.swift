import AuthenticationServices
import Foundation
import SwiftUI

enum AccountPasskeys {
    static func isAvailable(for url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host(),
              let associatedDomain = Bundle.main.object(forInfoDictionaryKey: "CardLedgerPasskeyDomain") as? String else {
            return false
        }
        return host == associatedDomain
    }

    @MainActor
    static func assertion(_ challenge: ServiceClient.PasskeyChallenge, for url: URL,
                          using controller: AuthorizationController) async throws -> [String: Any] {
        let provider = try provider(rpID: challenge.rpID, url: url)
        let request = provider.createCredentialAssertionRequest(challenge: try decode(challenge.challenge))
        request.userVerificationPreference = .required
        guard case .passkeyAssertion(let credential) = try await controller.performRequest(request) else {
            throw invalidResponse
        }
        return response(id: credential.credentialID, fields: [
            "clientDataJSON": encode(credential.rawClientDataJSON),
            "authenticatorData": encode(credential.rawAuthenticatorData),
            "signature": encode(credential.signature),
            "userHandle": encode(credential.userID)
        ])
    }

    @MainActor
    static func registration(_ options: ServiceClient.PasskeyRegistration, for url: URL,
                              using controller: AuthorizationController) async throws -> [String: Any] {
        let provider = try provider(rpID: options.rpID, url: url)
        let request = provider.createCredentialRegistrationRequest(challenge: try decode(options.challenge),
                                                                   name: options.name, userID: try decode(options.userID))
        request.userVerificationPreference = .required
        request.excludedCredentials = try options.excludedCredentialIDs.map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: try decode($0))
        }
        guard case .passkeyRegistration(let credential) = try await controller.performRequest(request),
              let attestation = credential.rawAttestationObject else {
            throw invalidResponse
        }
        return response(id: credential.credentialID, fields: [
            "clientDataJSON": encode(credential.rawClientDataJSON),
            "attestationObject": encode(attestation)
        ])
    }

    private static func provider(rpID: String, url: URL) throws -> ASAuthorizationPlatformPublicKeyCredentialProvider {
        guard isAvailable(for: url), rpID == url.host() else {
            throw ServiceError.server(code: "passkeys_unavailable", retryable: false)
        }
        return ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpID)
    }

    private static var invalidResponse: ServiceError { .server(code: "passkey_invalid", retryable: false) }

    private static func response(id: Data, fields: [String: String]) -> [String: Any] {
        let credentialID = encode(id)
        return ["id": credentialID, "rawId": credentialID, "type": "public-key",
                "clientExtensionResults": [String: String](), "response": fields]
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ text: String) throws -> Data {
        let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), !data.isEmpty else { throw invalidResponse }
        return data
    }
}
