import Foundation
import UIKit
import UserNotifications
import Amplify

/// Manages APNs registration and writing the device token to the backend.
///
/// Flow:
///  1. `requestAuthorization()` — ask the user, then register with APNs.
///  2. AppDelegate receives the APNs token and calls `register(deviceToken:)`.
///  3. We upsert a `DeviceToken` row (token + blank snsEndpointArn). The backend's
///     flight-refresh Lambda creates the SNS endpoint lazily on first push.
@MainActor
final class PushService: ObservableObject {
    static let shared = PushService()

    @Published private(set) var authorized = false

    /// The signed-in user's email, set by SessionStore once known. Needed to key
    /// the DeviceToken row to the owner.
    var ownerEmail: String?

    /// Pending token captured before we knew the user's email (e.g. APNs returns
    /// before sign-in completes). Flushed by `flushPendingIfReady()`.
    private var pendingToken: String?

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorized = granted
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            authorized = false
        }
    }

    /// Called from the AppDelegate with the raw APNs device token.
    func register(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await upsert(token: token) }
    }

    /// Call once the user's email becomes known to flush any token captured early.
    func flushPendingIfReady() {
        guard let token = pendingToken, ownerEmail != nil else { return }
        pendingToken = nil
        Task { await upsert(token: token) }
    }

    #if DEBUG
    private let isSandbox = true
    #else
    private let isSandbox = false
    #endif

    private func upsert(token: String) async {
        guard let email = ownerEmail?.lowercased() else {
            pendingToken = token // retry after sign-in
            return
        }

        // Stable id per (user, token) so re-registration overwrites rather than dupes.
        let id = "\(email)#\(token.prefix(16))"
        let doc = """
        mutation Upsert($input: CreateDeviceTokenInput!) {
          createDeviceToken(input: $input) { id }
        }
        """
        let input: [String: Any] = [
            "id": id,
            "ownerEmail": email,
            "token": token,
            "platform": isSandbox ? "APNS_SANDBOX" : "APNS",
        ]
        do {
            _ = try await Amplify.API.mutate(
                request: GraphQLRequest(document: doc, variables: ["input": input], responseType: JSONValue.self)
            )
        } catch {
            // If it already exists, update the token instead.
            await update(id: id, token: token, email: email)
        }
    }

    private func update(id: String, token: String, email: String) async {
        let doc = """
        mutation Update($input: UpdateDeviceTokenInput!) {
          updateDeviceToken(input: $input) { id }
        }
        """
        let input: [String: Any] = [
            "id": id,
            "ownerEmail": email,
            "token": token,
            "platform": isSandbox ? "APNS_SANDBOX" : "APNS",
        ]
        _ = try? await Amplify.API.mutate(
            request: GraphQLRequest(document: doc, variables: ["input": input], responseType: JSONValue.self)
        )
    }
}
