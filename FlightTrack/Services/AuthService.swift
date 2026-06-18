import Foundation
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
            lastError = error.localizedDescription
        }
    }

    func confirm(email: String, code: String) async {
        lastError = nil
        do {
            _ = try await Amplify.Auth.confirmSignUp(for: email, confirmationCode: code)
            state = .signedOut // user must now sign in
        } catch {
            lastError = error.localizedDescription
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
            lastError = error.localizedDescription
        }
    }

    func signOut() async {
        _ = await Amplify.Auth.signOut()
        state = .signedOut
    }
}
