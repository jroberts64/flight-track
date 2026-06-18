import SwiftUI

@main
struct FlightTrackApp: App {
    @StateObject private var auth = AuthService()
    @StateObject private var session = SessionStore()

    init() {
        AmplifyBootstrap.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(session)
        }
    }
}
