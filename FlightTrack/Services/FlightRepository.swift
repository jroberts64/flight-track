import Foundation
import Combine
import Amplify

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
        let json = try result.get()
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

    /// Flights belonging to a family member (by their profileId). The backend's
    /// owner rule means this only returns rows if cross-account read is granted;
    /// see README "Hardening" for tightening this with a custom resolver.
    func listFlights(forProfileId profileId: String) async throws -> [Flight] {
        try await listMyFlights(profileId: profileId)
    }

    // MARK: Real-time

    func subscribeToFlightChanges(profileId: String) -> AmplifyAsyncThrowingSequence<GraphQLSubscriptionEvent<JSONValue>> {
        let doc = """
        subscription OnChange($profileId: ID!) {
          onUpdateFlight(filter: { profileId: { eq: $profileId } }) { \(Self.flightFields) }
        }
        """
        return Amplify.API.subscribe(
            request: GraphQLRequest(document: doc, variables: ["profileId": profileId], responseType: JSONValue.self)
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

enum RepoError: Error { case malformedResponse }
