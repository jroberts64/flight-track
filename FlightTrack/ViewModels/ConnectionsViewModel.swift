import Foundation
import Combine
import Amplify

/// Manages connections (invitations) and loading connected users' flights.
@MainActor
final class ConnectionsViewModel: ObservableObject {
    @Published var links: [Connection] = []
    @Published var memberFlights: [String: [Flight]] = [:] // keyed by counterparty email
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let repo = FlightRepository.shared
    private var myEmail: String = ""
    private var myProfileId: String = ""
    private var subscriptionTask: Task<Void, Never>?

    func start(myEmail: String, myProfileId: String) {
        self.myEmail = myEmail
        self.myProfileId = myProfileId
        Task { await reload() }
        subscribeToConnectionFlights()
    }

    /// Live updates for connections' flights via the viewer-scoped subscription.
    /// On each change, replace the matching flight in the right counterparty's
    /// bucket (keyed by the flight's ownerEmail).
    private func subscribeToConnectionFlights() {
        subscriptionTask?.cancel()
        let viewer = myEmail
        subscriptionTask = Task {
            do {
                let sequence = repo.subscribeToConnectionFlightChanges(viewerEmail: viewer)
                for try await event in sequence {
                    guard case .data(let result) = event,
                          let json = try? result.get(),
                          let updated = json.value(at: "onConnectionFlightChange")?.asFlight
                    else { continue }
                    // Ignore my own flights here (My Flights handles those); only
                    // reflect connections' flights in the Connections screen.
                    let owner = (updated.ownerEmail ?? "").lowercased()
                    guard owner != myEmail.lowercased() else { continue }
                    var bucket = memberFlights[owner] ?? []
                    if let idx = bucket.firstIndex(where: { $0.id == updated.id }) {
                        bucket[idx] = updated
                    } else {
                        bucket.append(updated)
                    }
                    memberFlights[owner] = bucket
                }
            } catch {
                // Subscriptions can drop; screen still works via reload.
            }
        }
    }

    deinit { subscriptionTask?.cancel() }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            links = try await listMyLinks()
            // Keep MY flights' viewers in sync with current accepted connections.
            // Each user maintains their own flights (owner auth), so reconciling on
            // load is how both sides converge regardless of who accepted when.
            await reconcileMyViewers()
            await loadAcceptedMemberFlights()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rewrites the viewers on my own flights to (me + my accepted connections).
    private func reconcileMyViewers() async {
        guard !myEmail.isEmpty, !myProfileId.isEmpty else { return }
        let connections = links
            .filter { $0.status == .accepted }
            .map { $0.counterparty(for: myEmail) }
        do {
            try await repo.refreshViewers(
                ownerEmail: myEmail, profileId: myProfileId, connectionEmails: connections
            )
        } catch {
            // Non-fatal: viewers will reconcile on a later load.
        }
    }

    var pendingInvitesForMe: [Connection] {
        links.filter { $0.status == .pending && $0.isInvitee(myEmail) }
    }

    var connected: [Connection] {
        links.filter { $0.status == .accepted }
    }

    func invite(email: String) async {
        let target = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty, target != myEmail.lowercased() else {
            errorMessage = "Enter a valid email (not your own)."
            return
        }
        let doc = """
        mutation Create($input: CreateConnectionInput!) {
          createConnection(input: $input) { id inviterEmail inviteeEmail status }
        }
        """
        let vars: [String: Any] = [
            "input": [
                "inviterEmail": myEmail.lowercased(),
                "inviteeEmail": target,
                "status": "PENDING",
            ],
        ]
        do {
            _ = try await Amplify.API.mutate(
                request: GQL.userPool(doc, variables: vars)
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respond(to link: Connection, accept: Bool) async {
        let doc = """
        mutation Update($input: UpdateConnectionInput!) {
          updateConnection(input: $input) { id status }
        }
        """
        let vars: [String: Any] = [
            "input": ["id": link.id, "status": accept ? "ACCEPTED" : "DECLINED"],
        ]
        do {
            _ = try await Amplify.API.mutate(
                request: GQL.userPool(doc, variables: vars)
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func listMyLinks() async throws -> [Connection] {
        let doc = """
        query List($email: String!) {
          listConnections(filter: {
            or: [{ inviterEmail: { eq: $email } }, { inviteeEmail: { eq: $email } }]
          }) {
            items { id inviterEmail inviteeEmail status }
          }
        }
        """
        let result: GraphQLResponse<JSONValue> = try await Amplify.API.query(
            request: GQL.userPool(doc, variables: ["email": myEmail.lowercased()])
        )
        let items = try result.get().value(at: "listConnections.items")?.arrayValue ?? []
        return items.compactMap { item -> Connection? in
            guard let id = item.value(at: "id")?.stringValue,
                  let inviter = item.value(at: "inviterEmail")?.stringValue,
                  let invitee = item.value(at: "inviteeEmail")?.stringValue else { return nil }
            let status = LinkStatus(rawValue: item.value(at: "status")?.stringValue ?? "PENDING") ?? .pending
            return Connection(id: id, inviterEmail: inviter, inviteeEmail: invitee, status: status)
        }
    }

    private func loadAcceptedMemberFlights() async {
        memberFlights = [:]
        for link in connected {
            let email = link.counterparty(for: myEmail)
            do {
                guard let profile = try await repo.fetchProfile(byEmail: email) else { continue }
                let flights = try await repo.listFlights(forProfileId: profile.id)
                memberFlights[email] = flights
            } catch {
                // Skip members we can't load; surface a soft error.
                errorMessage = "Couldn't load flights for \(email)."
            }
        }
    }
}
