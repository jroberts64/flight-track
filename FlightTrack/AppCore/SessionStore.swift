import Foundation
import Combine

/// Holds per-session identity that views need after sign-in: the user's email
/// and their resolved UserProfile id (used to scope flight queries).
@MainActor
final class SessionStore: ObservableObject {
    @Published var email: String = ""
    @Published var profileId: String?
    @Published var isReady = false

    private let repo = FlightRepository.shared

    /// Called after sign-in to make sure a UserProfile exists.
    func prepare(auth: AuthService) async {
        do {
            let email = try await auth.currentEmail()
            let userId = try await auth.currentUserId()
            // displayName isn't always on the token; fall back to the email's local part.
            let displayName = email.split(separator: "@").first.map(String.init) ?? email
            let pid = try await repo.ensureProfile(userId: userId, email: email, displayName: displayName)
            self.email = email
            self.profileId = pid
            self.isReady = true

            // Hand the email to the push service and ask for notification
            // permission. If APNs already returned a token, it flushes now.
            PushService.shared.ownerEmail = email
            PushService.shared.flushPendingIfReady()
            await PushService.shared.requestAuthorization()
        } catch {
            self.isReady = false
        }
    }

    func clear() {
        email = ""
        profileId = nil
        isReady = false
        PushService.shared.ownerEmail = nil
    }
}
