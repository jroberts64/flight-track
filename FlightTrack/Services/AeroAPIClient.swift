import Foundation
import Amplify

enum AeroAPIError: Error, LocalizedError {
    case notFound
    case backend(String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notFound: return "No flight found for that flight number/date."
        case .backend(let m): return m
        case .decoding(let e): return "Couldn't read flight data: \(e.localizedDescription)"
        }
    }
}

/// Fetches live flight data from our backend (the `lookupFlight` AppSync query),
/// NOT from FlightAware directly. The AeroAPI key lives only in the Lambda, and
/// the Lambda caches results in DynamoDB to protect the AeroAPI budget.
///
/// This is the production-safe path: nothing secret ships in the app binary.
struct AeroAPIClient {
    static let shared = AeroAPIClient()

    /// Looks up a flight by number near a date. `near` is reduced to its UTC
    /// calendar date for the backend (AeroAPI is queried over a window).
    func fetchFlight(ident: String, near date: Date) async throws -> FlightLookupResult {
        let dateStr = DateOnly.string(date)
        let doc = """
        query Lookup($flightNumber: String!, $date: String!) {
          lookupFlight(flightNumber: $flightNumber, date: $date) {
            flightNumber faFlightId status originIata destinationIata
            scheduledOut scheduledIn estimatedOut estimatedIn actualOut actualIn
            originGate destinationGate originTerminal destinationTerminal
            progressPercent cached
          }
        }
        """
        let request = GQL.userPool(doc, variables: ["flightNumber": ident.uppercased(), "date": dateStr])

        let response: GraphQLResponse<JSONValue>
        do {
            response = try await Amplify.API.query(request: request)
        } catch {
            throw AeroAPIError.backend(error.localizedDescription)
        }

        let json: JSONValue
        switch response {
        case .success(let value):
            json = value
        case .failure(let responseError):
            // AppSync resolver errors (e.g. "No flight found", AeroAPI 4xx) arrive here.
            let message: String
            switch responseError {
            case .error(let errors), .partial(_, let errors):
                message = errors.first?.message ?? "Flight lookup failed."
            case .transformationError(_, let apiError):
                message = apiError.localizedDescription
            @unknown default:
                message = "Flight lookup failed."
            }
            if message.localizedCaseInsensitiveContains("no flight") {
                throw AeroAPIError.notFound
            }
            throw AeroAPIError.backend(message)
        }

        guard let node = json.value(at: "lookupFlight"),
              let result = node.asFlightLookupResult else {
            throw AeroAPIError.notFound
        }
        return result
    }
}
