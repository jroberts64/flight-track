import Foundation
import Combine
import Amplify

/// Drives the "Codes" screen: code-sharing groups, service links, and the most
/// recently received code per service (from push). Mirrors FlightsViewModel.
@MainActor
final class CodeGroupsViewModel: ObservableObject {
    @Published var groups: [CodeGroup] = []
    @Published var serviceLinks: [ServiceLink] = []
    /// Most recent code per service name, populated from `.codePushReceived`.
    /// Transient — cleared after a short while so a secret isn't left on screen.
    @Published var latestCodes: [String: CodeEvent] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// The address users forward their service code emails to.
    let forwardingAddress = "decode@app.jack-roberts.com"

    private let repo = CodeGroupRepository.shared
    private var ownerEmail: String = ""
    private var pushObserver: NSObjectProtocol?

    func start(ownerEmail: String) {
        self.ownerEmail = ownerEmail
        Task { await reload() }
        observePush()
    }

    func reload() async {
        guard !ownerEmail.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let g = repo.listMyGroups(ownerEmail: ownerEmail)
            async let l = repo.listMyServiceLinks(ownerEmail: ownerEmail)
            groups = try await g
            serviceLinks = try await l
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Accepted connections, for the group member picker. Reuses the flight
    /// repository's single source of truth rather than duplicating the query.
    func acceptedConnections() async -> [String] {
        (try? await FlightRepository.shared.acceptedConnectionEmails(for: ownerEmail)) ?? []
    }

    // MARK: Group CRUD

    func createGroup(name: String, members: [String]) async {
        do {
            let created = try await repo.createGroup(ownerEmail: ownerEmail, name: name, members: members)
            groups.append(created)
            groups.sort { $0.name < $1.name }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateGroup(_ group: CodeGroup, name: String, members: [String]) async {
        do {
            try await repo.updateGroupMembers(id: group.id, name: name, members: members)
            if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                groups[idx].name = name
                groups[idx].memberEmails = members.map { $0.lowercased() }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteGroup(_ group: CodeGroup) async {
        do {
            try await repo.deleteGroup(id: group.id)
            groups.removeAll { $0.id == group.id }
            // Orphaned service links remain; surface only the groups that exist.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Service-link CRUD

    func addServiceLink(serviceName: String, groupId: String, matchRules: String) async {
        do {
            let created = try await repo.createServiceLink(
                ownerEmail: ownerEmail, groupId: groupId, serviceName: serviceName, matchRules: matchRules
            )
            serviceLinks.append(created)
            serviceLinks.sort { $0.serviceName < $1.serviceName }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteServiceLink(_ link: ServiceLink) async {
        do {
            try await repo.deleteServiceLink(id: link.id)
            serviceLinks.removeAll { $0.id == link.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func groupName(for groupId: String) -> String {
        groups.first(where: { $0.id == groupId })?.name ?? "—"
    }

    // MARK: Push

    private func observePush() {
        guard pushObserver == nil else { return }
        pushObserver = NotificationCenter.default.addObserver(
            forName: .codePushReceived, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let service = note.userInfo?["service"] as? String,
                  let code = note.userInfo?["code"] as? String else { return }
            let group = note.userInfo?["group"] as? String ?? ""
            Task { @MainActor [weak self] in
                self?.latestCodes[service] = CodeEvent(
                    service: service, group: group, code: code, receivedAt: Date()
                )
            }
        }
    }

    deinit {
        if let pushObserver { NotificationCenter.default.removeObserver(pushObserver) }
    }
}
