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

/// Persistence + sync for flights, profiles, and connections.
///
/// This uses the Amplify GraphQL API (AppSync). The GraphQL documents are written
/// by hand so the file compiles before codegen runs; once you run `ampx sandbox`
/// and add the generated `API.swift` model types you can switch to the typed
/// `Amplify.API.query(request: .list(Flight.self))` style if you prefer.
///
/// Real-time: `subscribeToMyFlights` opens an AppSync subscription so the UI
/// updates live when a flight changes (including changes a connection can see).
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
            request: GQL.userPool(doc, variables: vars)
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
            request: GQL.userPool(doc, variables: ["email": email])
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
            request: GQL.userPool(doc, variables: ["profileId": profileId])
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

    /// Creates a flight via the custom `publishFlightCreate` mutation (NOT the
    /// generated `createFlight`), so the viewer-aware `onConnectionFlightCreate`
    /// subscription fires and the new flight appears live on connections'
    /// screens. Args are the flat field set (`createInput` == baseInput minus
    /// nils), matching the mutation's individual arguments.
    func createFlight(_ flight: Flight) async throws -> Flight {
        let doc = """
        mutation Create(
          $profileId: ID!, $ownerEmail: String!, $flightNumber: String!,
          $faFlightId: String, $departureDate: String!, $originIata: String!,
          $destinationIata: String!, $scheduledOut: String, $scheduledIn: String,
          $estimatedOut: String, $estimatedIn: String, $actualOut: String,
          $actualIn: String, $status: String, $originGate: String,
          $destinationGate: String, $originTerminal: String, $destinationTerminal: String,
          $progressPercent: Int, $lastRefreshedAt: String, $note: String,
          $viewers: [String]
        ) {
          publishFlightCreate(
            profileId: $profileId, ownerEmail: $ownerEmail, flightNumber: $flightNumber,
            faFlightId: $faFlightId, departureDate: $departureDate, originIata: $originIata,
            destinationIata: $destinationIata, scheduledOut: $scheduledOut, scheduledIn: $scheduledIn,
            estimatedOut: $estimatedOut, estimatedIn: $estimatedIn, actualOut: $actualOut,
            actualIn: $actualIn, status: $status, originGate: $originGate,
            destinationGate: $destinationGate, originTerminal: $originTerminal,
            destinationTerminal: $destinationTerminal, progressPercent: $progressPercent,
            lastRefreshedAt: $lastRefreshedAt, note: $note, viewers: $viewers
          ) { \(Self.flightFields) }
        }
        """
        let result: GraphQLResponse<JSONValue> = try await Amplify.API.mutate(
            request: GQL.userPool(doc, variables: flight.createInput)
        )
        guard let created = try result.get().value(at: "publishFlightCreate")?.asFlight else {
            throw RepoError.malformedResponse
        }
        return created
    }

    /// Persists flight changes via the custom `publishFlightUpdate` mutation
    /// (NOT the generated `updateFlight`), so the viewer-aware
    /// `onConnectionFlightChange` subscription fires for connections. Sends only
    /// the mutable live-status fields; the resolver does a partial update.
    func updateFlight(_ flight: Flight) async throws {
        let doc = """
        mutation Publish(
          $id: ID!, $status: String, $estimatedOut: String, $estimatedIn: String,
          $actualOut: String, $actualIn: String, $originGate: String,
          $destinationGate: String, $originTerminal: String, $destinationTerminal: String,
          $progressPercent: Int, $lastRefreshedAt: String, $note: String
        ) {
          publishFlightUpdate(
            id: $id, status: $status, estimatedOut: $estimatedOut, estimatedIn: $estimatedIn,
            actualOut: $actualOut, actualIn: $actualIn, originGate: $originGate,
            destinationGate: $destinationGate, originTerminal: $originTerminal,
            destinationTerminal: $destinationTerminal, progressPercent: $progressPercent,
            lastRefreshedAt: $lastRefreshedAt, note: $note
          ) { \(Self.flightFields) }
        }
        """
        // NOTE: must select the full field set (incl. `viewers`) so the
        // onConnectionFlightChange subscription's viewers-filter has fields to
        // match against — otherwise it silently won't fire for connections.
        _ = try await Amplify.API.mutate(
            request: GQL.userPool(doc, variables: flight.publishUpdateVars)
        )
    }

    /// Deletes a flight via the custom `publishFlightDelete` mutation (NOT the
    /// generated `deleteFlight`), so the viewer-aware `onConnectionFlightDelete`
    /// subscription fires and the row disappears live from connections' screens.
    /// Selects `viewers` so the subscription's viewer filter has a field to match.
    func deleteFlight(id: String) async throws {
        let doc = """
        mutation Delete($id: ID!) {
          publishFlightDelete(id: $id) { id ownerEmail flightNumber viewers }
        }
        """
        _ = try await Amplify.API.mutate(
            request: GQL.userPool(doc, variables: ["id": id])
        )
    }

    // MARK: Connection flights

    /// Flights belonging to a connection (by their profileId). Access is
    /// granted by the `viewers` list on each Flight (ownersDefinedIn), so this
    /// returns rows only where the caller's email is an accepted viewer.
    func listFlights(forProfileId profileId: String) async throws -> [Flight] {
        try await listMyFlights(profileId: profileId)
    }

    // MARK: viewers maintenance (cross-account read access)

    /// The emails of accepted connections for a user (the counterparties of
    /// ACCEPTED Connections). Single source of truth for who may view my flights.
    func acceptedConnectionEmails(for myEmail: String) async throws -> [String] {
        let email = myEmail.lowercased()
        let doc = """
        query List($email: String!) {
          listConnections(filter: {
            or: [{ inviterEmail: { eq: $email } }, { inviteeEmail: { eq: $email } }]
          }) {
            items { inviterEmail inviteeEmail status }
          }
        }
        """
        let result: GraphQLResponse<JSONValue> = try await Amplify.API.query(
            request: GQL.userPool(doc, variables: ["email": email])
        )
        let items = try result.get().value(at: "listConnections.items")?.arrayValue ?? []
        return items.compactMap { item -> String? in
            guard item.value(at: "status")?.stringValue == "ACCEPTED" else { return nil }
            let inviter = item.value(at: "inviterEmail")?.stringValue?.lowercased() ?? ""
            let invitee = item.value(at: "inviteeEmail")?.stringValue?.lowercased() ?? ""
            return inviter == email ? invitee : inviter
        }.uniqued()
    }

    /// Sets the `viewers` list on a flight (owner + accepted connection emails).
    /// Uses `publishFlightUpdate` so viewer changes also flow through the live
    /// subscription path.
    func setViewers(flightId: String, viewers: [String]) async throws {
        let doc = """
        mutation Publish($id: ID!, $viewers: [String]) {
          publishFlightUpdate(id: $id, viewers: $viewers) { \(Self.flightFields) }
        }
        """
        let vars: [String: Any] = ["id": flightId, "viewers": viewers]
        _ = try await Amplify.API.mutate(
            request: GQL.userPool(doc, variables: vars)
        )
    }

    /// Rewrites `viewers` on ALL of the owner's flights to `owner + connections`.
    /// Called when a connection is accepted/removed so existing flights pick up
    /// the change. Centralized here to avoid drift.
    func refreshViewers(ownerEmail: String, profileId: String, connectionEmails: [String]) async throws {
        let viewers = ([ownerEmail.lowercased()] + connectionEmails.map { $0.lowercased() }).uniqued()
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
            request: GQL.userPool(doc, variables: ["ownerEmail": ownerEmail.lowercased()])
        )
    }

    /// Viewer-scoped live subscription via the custom `onConnectionFlightChange`
    /// (bound to `publishFlightUpdate`). Delivers any flight where my email is in
    /// `viewers` — my own flights AND my connections' — so the Connections screen
    /// updates live. (The generated owner-scoped onUpdateFlight can't do this.)
    func subscribeToConnectionFlightChanges(viewerEmail: String) -> AmplifyAsyncThrowingSequence<GraphQLSubscriptionEvent<JSONValue>> {
        let doc = """
        subscription OnConnChange($viewerEmail: String!) {
          onConnectionFlightChange(viewerEmail: $viewerEmail) { \(Self.flightFields) }
        }
        """
        return Amplify.API.subscribe(
            request: GQL.userPool(doc, variables: ["viewerEmail": viewerEmail.lowercased()])
        )
    }

    /// Viewer-scoped live CREATE subscription via `onConnectionFlightCreate`
    /// (bound to `publishFlightCreate`). Fires when a new flight I can view —
    /// mine or a connection's — is created, so the UI can insert it without a
    /// reload. Delivers the new Flight; the view models add it by `id`.
    func subscribeToConnectionFlightCreates(viewerEmail: String) -> AmplifyAsyncThrowingSequence<GraphQLSubscriptionEvent<JSONValue>> {
        let doc = """
        subscription OnConnCreate($viewerEmail: String!) {
          onConnectionFlightCreate(viewerEmail: $viewerEmail) { \(Self.flightFields) }
        }
        """
        return Amplify.API.subscribe(
            request: GQL.userPool(doc, variables: ["viewerEmail": viewerEmail.lowercased()])
        )
    }

    /// Viewer-scoped live DELETE subscription via `onConnectionFlightDelete`
    /// (bound to `publishFlightDelete`). Fires when any flight I can view — mine
    /// or a connection's — is deleted, so the UI can remove it without a reload.
    /// Delivers the deleted Flight; the view models drop it by `id`.
    func subscribeToConnectionFlightDeletes(viewerEmail: String) -> AmplifyAsyncThrowingSequence<GraphQLSubscriptionEvent<JSONValue>> {
        let doc = """
        subscription OnConnDelete($viewerEmail: String!) {
          onConnectionFlightDelete(viewerEmail: $viewerEmail) { \(Self.flightFields) }
        }
        """
        return Amplify.API.subscribe(
            request: GQL.userPool(doc, variables: ["viewerEmail": viewerEmail.lowercased()])
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
