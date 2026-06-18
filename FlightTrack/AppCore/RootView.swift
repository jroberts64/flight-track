import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var session: SessionStore

    var body: some View {
        switch auth.state {
        case .unknown:
            ProgressView("Loading…")
                .task { await auth.bootstrap() }
        case .signedOut, .confirming:
            AuthView()
        case .signedIn:
            if session.isReady {
                MainTabView()
            } else {
                ProgressView("Setting up…")
                    .task { await session.prepare(auth: auth) }
            }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var session: SessionStore

    var body: some View {
        TabView {
            MyFlightsView()
                .tabItem { Label("My Flights", systemImage: "airplane") }
            FamilyView()
                .tabItem { Label("Family", systemImage: "person.2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var session: SessionStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: session.email)
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        Task {
                            await auth.signOut()
                            session.clear()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
