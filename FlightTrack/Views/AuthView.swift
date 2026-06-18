import SwiftUI

struct AuthView: View {
    @EnvironmentObject var auth: AuthService

    @State private var isSignUp = false
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                if case let .confirming(pendingEmail) = auth.state {
                    Section("Verify your email") {
                        Text("We sent a code to \(pendingEmail).")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("Verification code", text: $code)
                            .keyboardType(.numberPad)
                        Button("Confirm") {
                            Task { await auth.confirm(email: pendingEmail, code: code) }
                        }
                        .disabled(code.count < 4)
                    }
                } else {
                    Section(isSignUp ? "Create account" : "Sign in") {
                        if isSignUp {
                            TextField("Your name", text: $displayName)
                                .textContentType(.name)
                        }
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $password)
                            .textContentType(isSignUp ? .newPassword : .password)
                    }

                    Section {
                        Button(isSignUp ? "Create account" : "Sign in") {
                            Task {
                                if isSignUp {
                                    await auth.signUp(email: email, password: password, displayName: displayName)
                                } else {
                                    await auth.signIn(email: email, password: password)
                                }
                            }
                        }
                        .disabled(email.isEmpty || password.isEmpty || (isSignUp && displayName.isEmpty))

                        Button(isSignUp ? "Have an account? Sign in" : "New here? Create an account") {
                            isSignUp.toggle()
                        }
                        .font(.footnote)
                    }
                }

                if let error = auth.lastError {
                    Section {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("FlightTrack")
        }
    }
}
