import Foundation
import Combine
import Amplify

extension Array where Element: Hashable {
    /// Deduplicates while preserving first-seen order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// Persistence + sync for flights, profiles, and family links.
///
/// This uses the Amplify GraphQL API (AppSync). The GraphQL documents are written
/// by hand so the file compiles before codegen runs; once you run `ampx sandbox`
/// and add the generated `API.swift` model types you can switch to the typed
/// `Amplify.API.query(request: .list(Flight.self))` style if you prefer.
///
/// Real-time: `subscribeToMyFlights` opens an AppSync subscription so the UI
/// updates live when a flight changes (including changes a family member can see).
@MainActor
final class FlightRepository: ObservableObject {
    static let shared = FlightRepository()

    // MARK: Profiles

    /// Ensures a UserProfile row exists for the signed-in user; returns its id.
    func ensureProfile(userId: String, email: String, displayName: String) async throws -> String {
        // Try to find an existing profile owned by this user.
        if let existing = try await fetchProfile(byEmail: email) {
            return existing.id
        }
        let doc = """
        mutation Create($input: CreateUserProfileInput!) {
          createUserProfile(input: $input) { id displayName email homeAirport }
        }
        """
        let vars: [String: Any] = [
            "input": [
                "displayName": displayName,
                "email": email,
            ],
        ]
        let result: GraphQLResponse<JSONValue> = try await Amplify.API.mutate(
            request: GraphQLRequest(document: doc, variables: vars, responseType: JSONValue.self)
        )
        let json = try result.get()
        guard let id = json.value(at: "createUserProfile.id")?.stringValue else {
            throw RepoError.malformedResponse
        }
        return id
    }

    func fetchProfile(byEmail email: String) async throws -> UserProfile? {
        let doc = """
        query List($email: String!) {
          listUserProfiles(filter: { email: { eq: $email } }) {
            items { id displayName email homeAirport }
          }
        }
        """
        let result: GraphQLResponse<JSONValue> = try await Amplify.API.query(
            request: GraphQLRequest(document: doc, variables: ["email": email], responseType: JSONValue.self)
        )
        let json = try result.get()
        guard let item = json.value(at: "listUserProfiles.items")?.arrayValue?.first else { return nil }
        return item.asUserProfile
    }

    // MARK: Flights (mine)

    func listMyFlights(profileId: String) async throws -> [Flight] {
        let doc = """
        query List($profileId: ID!) {
          listFlights(filter: { profileId: { eq: $profileId } }) {
            items { \(Self.flightFields) }
          }
        }
        """
        let result: GraphQLResponse<JSONValue> = try await Amplify.API.query(
            request: GraphQLRequest(document: doc, variables: ["profileId": profileId], responseType: JSONValue.self)
        )
        // Tolerate partial responses: AppSync may return data alongside per-item
        // field errors (e.g. a row failing an auth check). Use whatever data is
        // present rather than throwing the whole list away.
        let json: JSONValue
        switch result {
        case .success(let value):
            json = value
        case .failure(let responseError):
            switch responseError {
            case .partial(let value, _):
                json = value
            case .error(let errors):
                throw RepoError.graphQL(errors.first?.message ?? "Query failed")
            case .transformationError:
                throw RepoError.malformedResponse
            @unknown default:
                throw RepoError.malformedResponse
            }
        }
        let items = json.value(at: "listFlights.items")?.arrayValue ?? []
        return items.compactMap { $0.asFlight }.sorted { ($0.effectiveDeparture ?? .distantFuture) < ($1.effectiveDeparture ?? .distantFuture) }
    }

    func createFlight(_ flight: Flight) async throws -> Flight {
        let doc = """
        mutation Create($input: CreateFlightInput!) {
          createFlight(input: $input) { \(Self.flightFields) }
        }
        """
        let result: GraphQLResponse<JSONValue> = try await Amplify.API.mutate(
            request: GraphQLRequest(document: doc, variables: ["input": flight.createInput], responseType: JSONValue.self)
        )
        guard let created = try result.get().value(at: "createFlight")?.asFlight else {
            throw RepoError.malformedResponse
        }
        return created
    }

    func updateFlight(_ flight: Flight) async throws {
        let doc = """
        mutation Update($input: UpdateFlightInput!) {
          updateFlight(input: $input) { id }
        }
        """
        _ = try await Amplify.API.mutate(
            request: GraphQLRequest(document: doc, variables: ["input": flight.updateInput], responseType: JSONValue.self)
        )
    }

    func deleteFlight(id: String) async throws {
        let doc = """
        mutation Delete($input: DeleteFlightInput!) {
          deleteFlight(input: $input) { id }
        }
        """
        _ = try await Amplify.API.mutate(
            request: GraphQLRequest(document: doc, variables: ["input": ["id": id]], responseType: JSONValue.self)
        )
    }

    // MARK: Family flights

    /// Flights belonging to a family member (by their profileId). Access is
    /// granted by the `viewers` list on each Flight (ownersDefinedIn), so this
    /// returns rows only where the caller's email is an accepted viewer.
    func listFlights(forProfileId profileId: String) async throws -> [Flight] {
        try await listMyFlights(profileId: profileId)
    }

    // MARK: viewers maintenance (cross-family read access)

    /// The emails of accepted family members for a user (the counterparties of
    /// ACCEPTED FamilyLinks). Single source of truth for who may view my flights.
    func acceptedFamilyEmails(for myEmail: String) async throws -> [String] {
        let email = myEmail.lowercased()
        let doc = """
        query List($email: String!) {
          listFamilyLinks(filter: {
            or: [{ inviterEmail: { eq: $email } }, { inviteeEmail: { eq: $email } }]
          }) {
            items { inviterEmail inviteeEmail status }
          }
        }
        """
        let result: GraphQLResponse<JSONValue> = try await Amplify.API.query(
            request: GraphQLRequest(document: doc, variables: ["email": email], responseType: JSONValue.self)
        )
        let items = try result.get().value(at: "listFamilyLinks.items")?.arrayValue ?? []
        return items.compactMap { item -> String? in
            guard item.value(at: "status")?.stringValue == "ACCEPTED" else { return nil }
            let inviter = item.value(at: "inviterEmail")?.stringValue?.lowercased() ?? ""
            let invitee = item.value(at: "inviteeEmail")?.stringValue?.lowercased() ?? ""
            return inviter == email ? invitee : inviter
        }.uniqued()
    }

    /// Sets the `viewers` list on a flight (owner + accepted family emails).
    func setViewers(flightId: String, viewers: [String]) async throws {
        let doc = """
        mutation Update($input: UpdateFlightInput!) {
          updateFlight(input: $input) { id }
        }
        """
        let vars: [String: Any] = ["input": ["id": flightId, "viewers": viewers]]
        _ = try await Amplify.API.mutate(
            request: GraphQLRequest(document: doc, variables: vars, responseType: JSONValue.self)
        )
    }

    /// Rewrites `viewers` on ALL of the owner's flights to `owner + family`.
    /// Called when a family link is accepted/removed so existing flights pick up
    /// the change. Centralized here to avoid drift.
    func refreshViewers(ownerEmail: String, profileId: String, familyEmails: [String]) async throws {
        let viewers = ([ownerEmail.lowercased()] + familyEmails.map { $0.lowercased() }).uniqued()
        let mine = try await listMyFlights(profileId: profileId)
        for flight in mine {
            try await setViewers(flightId: flight.id, viewers: viewers)
        }
    }

    // MARK: Real-time

    /// Owner-scoped subscription. With ownerDefinedIn('ownerEmail') auth, AppSync
    /// requires the `ownerEmail` argument to equal the subscriber's email — it is
    /// NOT a filter. Passing a profileId filter instead gets the connection
    /// rejected (surfaces as GraphQLResponseError 0).
    func subscribeToFlightChanges(ownerEmail: String) -> AmplifyAsyncThrowingSequence<GraphQLSubscriptionEvent<JSONValue>> {
        let doc = """
        subscription OnChange($ownerEmail: String!) {
          onUpdateFlight(ownerEmail: $ownerEmail) { \(Self.flightFields) }
        }
        """
        return Amplify.API.subscribe(
            request: GraphQLRequest(
                document: doc,
                variables: ["ownerEmail": ownerEmail.lowercased()],
                responseType: JSONValue.self
            )
        )
    }

    // MARK: Shared GraphQL field set

    private static let flightFields = """
    id profileId ownerEmail flightNumber faFlightId departureDate originIata destinationIata
    scheduledOut scheduledIn estimatedOut estimatedIn actualOut actualIn
    status originGate destinationGate originTerminal destinationTerminal
    progressPercent lastRefreshedAt note
    """
}

enum RepoError: Error, LocalizedError {
    case malformedResponse
    case graphQL(String)

    var errorDescription: String? {
        switch self {
        case .malformedResponse: return "The server response couldn't be read."
        case .graphQL(let m): return m
        }
    }
}
