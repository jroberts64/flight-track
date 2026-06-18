import Foundation

enum AeroAPIError: Error, LocalizedError {
    case missingKey
    case badResponse(Int)
    case notFound
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "AeroAPI key is not configured."
        case .badResponse(let code): return "AeroAPI returned status \(code)."
        case .notFound: return "No flight found for that flight number/date."
        case .decoding(let e): return "Couldn't read AeroAPI response: \(e.localizedDescription)"
        }
    }
}

/// Thin client for FlightAware AeroAPI.
///
/// ⚠️ For development only. In production the API key must NOT live in the app
/// binary — proxy these calls through an Amplify Function (see README "Hardening").
/// This client reads the key from the `AERO_API_KEY` Info.plist value so you can
/// supply it via an untracked .xcconfig.
struct AeroAPIClient {
    static let shared = AeroAPIClient()

    private let baseURL = URL(string: "https://aeroapi.flightaware.com/aeroapi")!

    private var apiKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "AERO_API_KEY") as? String
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Fetches the best-matching flight for a flight number around a given date.
    /// AeroAPI's `/flights/{ident}` returns recent + upcoming flights; we pick the
    /// one whose scheduled departure is closest to `date`.
    func fetchFlight(ident: String, near date: Date) async throws -> AeroFlight {
        guard let apiKey, !apiKey.isEmpty else { throw AeroAPIError.missingKey }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("flights/\(ident)"),
            resolvingAgainstBaseURL: false
        )!
        // Widen the window a little around the requested date.
        let start = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
        let end = Calendar.current.date(byAdding: .day, value: 2, to: date) ?? date
        let iso = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "start", value: iso.string(from: start)),
            URLQueryItem(name: "end", value: iso.string(from: end)),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AeroAPIError.badResponse(-1)
        }
        guard (200...299).contains(http.statusCode) else {
            throw AeroAPIError.badResponse(http.statusCode)
        }

        let parsed: AeroFlightsResponse
        do {
            parsed = try decoder.decode(AeroFlightsResponse.self, from: data)
        } catch {
            throw AeroAPIError.decoding(error)
        }

        let candidates = parsed.flights
        guard !candidates.isEmpty else { throw AeroAPIError.notFound }

        // Pick the candidate whose scheduled departure is closest to `date`.
        let best = candidates.min { lhs, rhs in
            let l = lhs.scheduledOut ?? .distantPast
            let r = rhs.scheduledOut ?? .distantPast
            return abs(l.timeIntervalSince(date)) < abs(r.timeIntervalSince(date))
        }
        guard let best else { throw AeroAPIError.notFound }
        return best
    }
}

extension AeroFlight {
    /// Applies this live snapshot onto an existing Flight (or a fresh one).
    func apply(to flight: inout Flight) {
        flight.faFlightId = faFlightId ?? flight.faFlightId
        flight.status = mappedStatus
        flight.progressPercent = progressPercent
        flight.scheduledOut = scheduledOut ?? flight.scheduledOut
        flight.scheduledIn = scheduledIn ?? flight.scheduledIn
        flight.estimatedOut = estimatedOut ?? flight.estimatedOut
        flight.estimatedIn = estimatedIn ?? flight.estimatedIn
        flight.actualOut = actualOut ?? flight.actualOut
        flight.actualIn = actualIn ?? flight.actualIn
        flight.originGate = gateOrigin ?? flight.originGate
        flight.destinationGate = gateDestination ?? flight.destinationGate
        flight.originTerminal = terminalOrigin ?? flight.originTerminal
        flight.destinationTerminal = terminalDestination ?? flight.destinationTerminal
        if let iata = origin?.iata { flight.originIata = iata }
        if let iata = destination?.iata { flight.destinationIata = iata }
        flight.lastRefreshedAt = Date()
    }
}
