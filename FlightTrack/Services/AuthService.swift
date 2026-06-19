import Foundation
import Combine
import Amplify

/// Wraps Amplify Auth (Cognito) and publishes the current session state.
@MainActor
final class AuthService: ObservableObject {
    enum State: Equatable {
        case unknown
        case signedOut
        case confirming(email: String)   // awaiting email verification code
        case signedIn(email: String)
    }

    @Published private(set) var state: State = .unknown
    @Published var lastError: String?

    func bootstrap() async {
        do {
            let session = try await Amplify.Auth.fetchAuthSession()
            if session.isSignedIn, let email = try? await currentEmail() {
                state = .signedIn(email: email)
            } else {
                state = .signedOut
            }
        } catch {
            state = .signedOut
        }
    }

    func currentEmail() async throws -> String {
        let attrs = try await Amplify.Auth.fetchUserAttributes()
        if let email = attrs.first(where: { $0.key == .email })?.value {
            return email
        }
        throw AuthError.unknown("No email on account", nil)
    }

    func currentUserId() async throws -> String {
        let user = try await Amplify.Auth.getCurrentUser()
        return user.userId
    }

    func signUp(email: String, password: String, displayName: String) async {
        lastError = nil
        // Validate the password locally first so the user gets a clear message
        // instead of Cognito's opaque error.
        if let problem = Self.passwordProblem(password) {
            lastError = problem
            return
        }
        do {
            let options = AuthSignUpRequest.Options(userAttributes: [
                AuthUserAttribute(.email, value: email),
                AuthUserAttribute(.preferredUsername, value: displayName),
            ])
            let result = try await Amplify.Auth.signUp(
                username: email, password: password, options: options
            )
            if case .confirmUser = result.nextStep {
                state = .confirming(email: email)
            } else {
                await signIn(email: email, password: password)
            }
        } catch {
            lastError = friendlyMessage(error)
        }
    }

    func confirm(email: String, code: String) async {
        lastError = nil
        do {
            _ = try await Amplify.Auth.confirmSignUp(for: email, confirmationCode: code)
            state = .signedOut // user must now sign in
        } catch {
            lastError = friendlyMessage(error)
        }
    }

    func signIn(email: String, password: String) async {
        lastError = nil
        do {
            let result = try await Amplify.Auth.signIn(username: email, password: password)
            if result.isSignedIn {
                state = .signedIn(email: email)
            } else if case .confirmSignUp = result.nextStep {
                state = .confirming(email: email)
            }
        } catch {
            lastError = friendlyMessage(error)
        }
    }

    func signOut() async {
        _ = await Amplify.Auth.signOut()
        state = .signedOut
    }
}

extension AuthService {
    /// Cognito's default password policy (mirrors the user pool config). Used to
    /// validate before calling Cognito so users get a clear, immediate message
    /// instead of the opaque `AuthError error 1`.
    static func passwordProblem(_ password: String) -> String? {
        var unmet: [String] = []
        if password.count < 8 { unmet.append("at least 8 characters") }
        if !password.contains(where: \.isUppercase) { unmet.append("an uppercase letter") }
        if !password.contains(where: \.isLowercase) { unmet.append("a lowercase letter") }
        if !password.contains(where: \.isNumber) { unmet.append("a number") }
        let symbols = CharacterSet(charactersIn: "^$*.[]{}()?\"!@#%&/\\,><':;|_~`+=- ")
        if !password.unicodeScalars.contains(where: { symbols.contains($0) }) {
            unmet.append("a symbol")
        }
        guard !unmet.isEmpty else { return nil }
        return "Password needs " + unmet.joined(separator: ", ") + "."
    }

    /// Turns Amplify's terse AuthError into something a person can act on.
    func friendlyMessage(_ error: Error) -> String {
        guard let authError = error as? AuthError else { return error.localizedDescription }
        switch authError {
        case .validation:
            return "Please check the form and try again."
        case .service(let summary, _, let underlying):
            let text = "\(summary) \(String(describing: underlying))".lowercased()
            if text.contains("password") {
                return Self.passwordProblem("")
                    ?? "Password doesn't meet the requirements (8+ chars, upper, lower, number, symbol)."
            }
            if text.contains("usernameexists") || text.contains("already exists") {
                return "An account with that email already exists. Try signing in."
            }
            if text.contains("usernotfound") || text.contains("notauthorized") {
                return "Incorrect email or password."
            }
            if text.contains("codemismatch") {
                return "That verification code isn't right. Check the email and retry."
            }
            if text.contains("expiredcode") {
                return "That code has expired. Request a new one."
            }
            if text.contains("invalidparameter") && text.contains("email") {
                return "That doesn't look like a valid email address."
            }
            return summary
        default:
            return authError.errorDescription
        }
    }
}
