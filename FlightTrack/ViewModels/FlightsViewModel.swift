import Foundation
import Combine
import Amplify

/// Drives the "My Flights" screen and the add-flight flow.
@MainActor
final class FlightsViewModel: ObservableObject {
    @Published var flights: [Flight] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let repo = FlightRepository.shared
    private var profileId: String?
    private var ownerEmail: String?
    private var subscriptionTask: Task<Void, Never>?

    func start(profileId: String, ownerEmail: String) {
        self.profileId = profileId
        self.ownerEmail = ownerEmail
        Task { await reload() }
        subscribe(profileId: profileId)
    }

    func reload() async {
        guard let profileId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            flights = try await repo.listMyFlights(profileId: profileId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Looks up the flight on AeroAPI, then persists it.
    func addFlight(flightNumber: String, date: Date, note: String?) async {
        guard let profileId else { return }
        isLoading = true
        defer { isLoading = false }

        var flight = Flight(
            id: UUID().uuidString, // placeholder; backend assigns real id on create
            profileId: profileId,
            ownerEmail: ownerEmail,
            flightNumber: flightNumber.uppercased(),
            faFlightId: nil,
            departureDate: date,
            originIata: "",
            destinationIata: "",
            status: .scheduled,
            note: note?.isEmpty == true ? nil : note
        )

        // Enrich with live data; tolerate failures so the flight can still be saved.
        do {
            let live = try await AeroAPIClient.shared.fetchFlight(ident: flight.flightNumber, near: date)
            live.apply(to: &flight)
        } catch {
            errorMessage = "Saved without live data: \(error.localizedDescription)"
        }

        do {
            let created = try await repo.createFlight(flight)
            flights.append(created)
            flights.sort { ($0.effectiveDeparture ?? .distantFuture) < ($1.effectiveDeparture ?? .distantFuture) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshStatus(for flight: Flight) async {
        var updated = flight
        do {
            let live = try await AeroAPIClient.shared.fetchFlight(ident: flight.flightNumber, near: flight.departureDate)
            live.apply(to: &updated)
            try await repo.updateFlight(updated)
            if let idx = flights.firstIndex(where: { $0.id == updated.id }) {
                flights[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ flight: Flight) async {
        do {
            try await repo.deleteFlight(id: flight.id)
            flights.removeAll { $0.id == flight.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func subscribe(profileId: String) {
        subscriptionTask?.cancel()
        subscriptionTask = Task {
            do {
                let sequence = repo.subscribeToFlightChanges(profileId: profileId)
                for try await event in sequence {
                    switch event {
                    case .data(let result):
                        if let json = try? result.get(),
                           let updated = json.value(at: "onUpdateFlight")?.asFlight {
                            if let idx = flights.firstIndex(where: { $0.id == updated.id }) {
                                flights[idx] = updated
                            } else {
                                flights.append(updated)
                            }
                        }
                    case .connection:
                        break
                    }
                }
            } catch {
                // Subscriptions can drop; UI still works via manual reload.
            }
        }
    }

    deinit { subscriptionTask?.cancel() }
}
