import SwiftUI

struct FamilyView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm = FamilyViewModel()
    @State private var inviteEmail = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Invite family") {
                    HStack {
                        TextField("Family member's email", text: $inviteEmail)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Invite") {
                            Task {
                                await vm.invite(email: inviteEmail)
                                inviteEmail = ""
                            }
                        }
                        .disabled(inviteEmail.isEmpty)
                    }
                }

                if !vm.pendingInvitesForMe.isEmpty {
                    Section("Invitations") {
                        ForEach(vm.pendingInvitesForMe) { link in
                            HStack {
                                Text(link.inviterEmail)
                                Spacer()
                                Button("Accept") { Task { await vm.respond(to: link, accept: true) } }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                                Button("Decline") { Task { await vm.respond(to: link, accept: false) } }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }

                ForEach(vm.connected) { link in
                    let email = link.counterparty(for: session.email)
                    Section(email) {
                        let flights = vm.memberFlights[email] ?? []
                        if flights.isEmpty {
                            Text("No upcoming flights.").foregroundStyle(.secondary).font(.footnote)
                        } else {
                            ForEach(flights) { FlightRowView(flight: $0) }
                        }
                    }
                }
            }
            .navigationTitle("Family")
            .refreshable { await vm.reload() }
            .alert("Heads up", isPresented: .constant(vm.errorMessage != nil)) {
                Button("OK") { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
        }
        .task { vm.start(myEmail: session.email) }
    }
}
