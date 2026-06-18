import SwiftUI

@main
struct FlightTrackApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var auth = AuthService()
    @StateObject private var session = SessionStore()
    @StateObject private var push = PushService.shared

    init() {
        AmplifyBootstrap.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(session)
                .environmentObject(push)
        }
    }
}
