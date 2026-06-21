import UIKit
import UserNotifications

extension Notification.Name {
    /// Posted when a flight-change push is received (foreground, background, or
    /// tapped). `userInfo["flightId"]` holds the changed flight's id when known.
    static let flightPushReceived = Notification.Name("flightPushReceived")
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
        postFlightPush(notification.request.content.userInfo)
        return [.banner, .sound, .list]
    }

    // User tapped the notification — refresh so the opened app isn't stale.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        postFlightPush(response.notification.request.content.userInfo)
    }

    // Silent/background delivery (content-available): wake, refresh, report.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        postFlightPush(userInfo)
        return .newData
    }

    private func postFlightPush(_ userInfo: [AnyHashable: Any]) {
        var info: [String: Any] = [:]
        if let flightId = userInfo["flightId"] as? String { info["flightId"] = flightId }
        NotificationCenter.default.post(name: .flightPushReceived, object: nil, userInfo: info)
    }
}
