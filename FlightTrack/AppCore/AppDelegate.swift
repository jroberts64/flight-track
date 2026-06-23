import UIKit
import UserNotifications

extension Notification.Name {
    /// Posted when a flight-change push is received (foreground, background, or
    /// tapped). `userInfo["flightId"]` holds the changed flight's id when known.
    static let flightPushReceived = Notification.Name("flightPushReceived")

    /// Posted when a shared-service-code push is received. `userInfo` holds
    /// `service`, `group`, and `code` (the payload carries `kind == "code"`).
    static let codePushReceived = Notification.Name("codePushReceived")
}

/// SwiftUI apps still need a UIApplicationDelegate to receive the APNs device
/// token. Bridged into the App via @UIApplicationDelegateAdaptor.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushService.shared.register(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed: \(error.localizedDescription)")
    }

    // Show banners even when the app is foregrounded, and refresh in place so
    // the flight list reflects the change behind the banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        route(notification.request.content.userInfo)
        return [.banner, .sound, .list]
    }

    // User tapped the notification — refresh so the opened app isn't stale.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        route(response.notification.request.content.userInfo)
    }

    // Silent/background delivery (content-available): wake, refresh, report.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        route(userInfo)
        return .newData
    }

    /// Routes an incoming push to the right NotificationCenter event based on
    /// its `kind`. Code pushes carry `kind == "code"`; everything else is a
    /// flight change (the original payload had no `kind`).
    private func route(_ userInfo: [AnyHashable: Any]) {
        if (userInfo["kind"] as? String) == "code" {
            var info: [String: Any] = [:]
            if let service = userInfo["service"] as? String { info["service"] = service }
            if let group = userInfo["group"] as? String { info["group"] = group }
            if let code = userInfo["code"] as? String { info["code"] = code }
            NotificationCenter.default.post(name: .codePushReceived, object: nil, userInfo: info)
            return
        }
        var info: [String: Any] = [:]
        if let flightId = userInfo["flightId"] as? String { info["flightId"] = flightId }
        NotificationCenter.default.post(name: .flightPushReceived, object: nil, userInfo: info)
    }
}
