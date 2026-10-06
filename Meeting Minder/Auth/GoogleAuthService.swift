import AppKit
import Combine
import Foundation
import os

/// Owns the Google OAuth 2.0 installed-application flow (loopback redirect + PKCE)
/// and vends fresh access tokens to the calendar layer.
@MainActor
final class GoogleAuthService: ObservableObject {

    enum State: Equatable {
        case notConfigured
        case signedOut
        case signingIn
        case signedIn(email: String?)
    }

    enum AuthError: LocalizedError {
        case notConfigured
        case stateMismatch
        case google(String, String?)
        case missingRefreshToken
        case invalidResponse
        case sessionExpired

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Add a Google OAuth client ID in Settings first."
            case .stateMismatch:
                return "The sign-in response did not match this request. Please try again."
            case .google(let code, let description):
                return description.map { "\($0) (\(code))" } ?? "Google returned an error: \(code)"
            case .missingRefreshToken:
                return "Google did not return a refresh token. Remove Meeting Minder from your Google account permissions and sign in again."
            case .invalidResponse:
                return "Unexpected response from Google."
            case .sessionExpired:
                return "Your Google session expired. Please sign in again."
            }
        }
    }

    private enum Endpoint {
        static let authorize = "https://accounts.google.com/o/oauth2/v2/auth"
        static let token = "https://oauth2.googleapis.com/token"
        static let revoke = "https://oauth2.googleapis.com/revoke"
    }

    private static let scopes = [
        "openid",
        "email",
        "https://www.googleapis.com/auth/calendar.readonly",
    ]

    @Published private(set) var state: State = .signedOut
    @Published private(set) var lastError: String?

    private let settings: AppSettings
    private let store: TokenStore
    private var credentials: StoredCredentials?
    private var refreshTask: Task<String, Error>?
    private var activeServer: LoopbackRedirectServer?

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var email: String? {
        if case .signedIn(let email) = state { return email }
        return nil
    }

    init(settings: AppSettings = .shared, store: TokenStore = .shared) {
        self.settings = settings
        self.store = store
        reloadFromDisk()
    }

    func reloadFromDisk() {
        credentials = store.load()
        if credentials != nil {
            state = .signedIn(email: credentials?.email)
        } else {
            state = settings.isConfigured ? .signedOut : .notConfigured
        }
    }

    /// Re-evaluates `.notConfigured` after the user edits credentials in Settings.
    func settingsChanged() {
        if credentials == nil {
            state = settings.isConfigured ? .signedOut : .notConfigured
        }
    }

    // MARK: - Sign in / out

    func signIn() async {
        guard settings.isConfigured else {
            state = .notConfigured
            lastError = AuthError.notConfigured.localizedDescription
            return
        }
        if case .signingIn = state { return }  // already in flight
        await performSignIn()
    }

    private func performSignIn() async {
        state = .signingIn
        lastError = nil

        let server = LoopbackRedirectServer()
        activeServer = server
        defer { activeServer = nil }

        do {
            _ = try await server.start()
            let pkce = PKCEPair()
            let expectedState = PKCEPair.randomURLSafeString(byteCount: 16)
            let redirectURI = server.redirectURI

            guard let authURL = authorizationURL(pkce: pkce, state: expectedState, redirectURI: redirectURI) else {
                throw AuthError.invalidResponse
            }
            NSWorkspace.shared.open(authURL)

            let params = try await server.waitForRedirect()

            if let error = params["error"] {
                throw AuthError.google(error, params["error_description"])
            }
            guard params["state"] == expectedState else { throw AuthError.stateMismatch }
            guard let code = params["code"] else { throw AuthError.invalidResponse }

            let response = try await exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI)
            guard let refreshToken = response.refreshToken else { throw AuthError.missingRefreshToken }

            let credentials = StoredCredentials(
                refreshToken: refreshToken,
                accessToken: response.accessToken,
                accessTokenExpiry: response.expiresIn.map { Date().addingTimeInterval($0) },
                email: response.idToken.flatMap(Self.email(fromIDToken:)),
                grantedScopes: response.scope
            )
            self.credentials = credentials
            store.save(credentials)
            state = .signedIn(email: credentials.email)
            Log.auth.info("Signed in successfully")
        } catch {
            server.stop()
            state = credentials == nil ? (settings.isConfigured ? .signedOut : .notConfigured) : .signedIn(email: credentials?.email)
            lastError = error.localizedDescription
            Log.auth.error("Sign-in failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancelSignIn() {
        activeServer?.stop()
    }

    func signOut() async {
        let token = credentials?.refreshToken
        credentials = nil
        refreshTask?.cancel()
        refreshTask = nil
        store.clear()
        state = settings.isConfigured ? .signedOut : .notConfigured
        lastError = nil

        // Best effort: tell Google to drop the grant too.
        if let token {
            var request = URLRequest(url: URL(string: Endpoint.revoke)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("token=\(token.formURLEncoded)".utf8)
            _ = try? await URLSession.shared.data(for: request)
        }
        Log.auth.info("Signed out")
    }

    // MARK: - Tokens

    /// Returns a valid access token, refreshing if necessary. Concurrent callers share one refresh.
    func accessToken() async throws -> String {
        guard let credentials else { throw AuthError.sessionExpired }
        if credentials.hasUsableAccessToken, let token = credentials.accessToken {
            return token
        }
        return try await refreshAccessToken()
    }

    /// Forces a refresh even if the cached token looks valid — used after a 401.
    @discardableResult
    func refreshAccessToken() async throws -> String {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let refreshToken = credentials?.refreshToken else { throw AuthError.sessionExpired }

        let task = Task { () throws -> String in
            defer { self.refreshTask = nil }
            do {
                let response = try await self.exchangeRefresh(token: refreshToken)
                guard let accessToken = response.accessToken else { throw AuthError.invalidResponse }

                var updated = self.credentials ?? StoredCredentials(refreshToken: refreshToken)
                updated.accessToken = accessToken
                updated.accessTokenExpiry = response.expiresIn.map { Date().addingTimeInterval($0) }
                if let newRefresh = response.refreshToken { updated.refreshToken = newRefresh }
                if let email = response.idToken.flatMap(Self.email(fromIDToken:)) { updated.email = email }

                self.credentials = updated
                self.store.save(updated)
                self.state = .signedIn(email: updated.email)
                return accessToken
            } catch let error as AuthError {
                // A revoked or expired grant is unrecoverable — drop it so the UI prompts a re-auth.
                if case .google(let code, _) = error, code == "invalid_grant" {
                    self.credentials = nil
                    self.store.clear()
                    self.state = self.settings.isConfigured ? .signedOut : .notConfigured
                    self.lastError = AuthError.sessionExpired.localizedDescription
                    throw AuthError.sessionExpired
                }
                throw error
            }
        }
        refreshTask = task
        return try await task.value
    }

    // MARK: - Requests

    private func authorizationURL(pkce: PKCEPair, state: String, redirectURI: String) -> URL? {
        var components = URLComponents(string: Endpoint.authorize)
        components?.queryItems = [
            .init(name: "client_id", value: settings.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            // Force the consent screen so Google reliably returns a refresh token.
            .init(name: "prompt", value: "consent"),
        ]
        return components?.url
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> TokenResponse {
        var fields = [
            "code": code,
            "client_id": settings.clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        if !settings.clientSecret.isEmpty { fields["client_secret"] = settings.clientSecret }
        return try await postForm(to: Endpoint.token, fields: fields)
    }

    private func exchangeRefresh(token: String) async throws -> TokenResponse {
        var fields = [
            "refresh_token": token,
            "client_id": settings.clientID,
            "grant_type": "refresh_token",
        ]
        if !settings.clientSecret.isEmpty { fields["client_secret"] = settings.clientSecret }
        return try await postForm(to: Endpoint.token, fields: fields)
    }

    private func postForm(to urlString: String, fields: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: urlString) else { throw AuthError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields
            .map { "\($0.key.formURLEncoded)=\($0.value.formURLEncoded)" }
            .joined(separator: "&").utf8)

        let (data, _) = try await URLSession.shared.data(for: request)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(TokenResponse.self, from: data) else {
            throw AuthError.invalidResponse
        }
        if let error = response.error {
            throw AuthError.google(error, response.errorDescription)
        }
        return response
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?
        let expiresIn: TimeInterval?
        let scope: String?
        let error: String?
        let errorDescription: String?
    }

    /// Pulls the `email` claim out of an unverified ID token. The token came straight
    /// from Google's TLS endpoint, and it is only used to label the menu.
    private static func email(fromIDToken token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let payload = Data.fromBase64URL(String(segments[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return json["email"] as? String
    }
}

extension String {
    var formURLEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
