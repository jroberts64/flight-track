import Foundation

/// Decodable models matching the subset of the FlightAware AeroAPI
/// `GET /flights/{ident}` response we care about.
/// Docs: https://www.flightaware.com/aeroapi/portal/documentation
struct AeroFlightsResponse: Decodable {
    let flights: [AeroFlight]
}

struct AeroFlight: Decodable {
    let faFlightId: String?
    let ident: String?
    let status: String?
    let progressPercent: Int?
    let cancelled: Bool?
    let diverted: Bool?

    let origin: AeroAirport?
    let destination: AeroAirport?

    let scheduledOut: Date?
    let estimatedOut: Date?
    let actualOut: Date?
    let scheduledIn: Date?
    let estimatedIn: Date?
    let actualIn: Date?

    let gateOrigin: String?
    let gateDestination: String?
    let terminalOrigin: String?
    let terminalDestination: String?

    enum CodingKeys: String, CodingKey {
        case faFlightId = "fa_flight_id"
        case ident
        case status
        case progressPercent = "progress_percent"
        case cancelled
        case diverted
        case origin
        case destination
        case scheduledOut = "scheduled_out"
        case estimatedOut = "estimated_out"
        case actualOut = "actual_out"
        case scheduledIn = "scheduled_in"
        case estimatedIn = "estimated_in"
        case actualIn = "actual_in"
        case gateOrigin = "gate_origin"
        case gateDestination = "gate_destination"
        case terminalOrigin = "terminal_origin"
        case terminalDestination = "terminal_destination"
    }

    /// Maps AeroAPI's free-form status into our enum.
    var mappedStatus: FlightStatus {
        if cancelled == true { return .cancelled }
        if diverted == true { return .diverted }
        guard let s = status?.lowercased() else { return .unknown }
        if s.contains("scheduled") { return .scheduled }
        if s.contains("boarding") { return .boarding }
        if s.contains("en route") || s.contains("airborne") { return .enroute }
        if s.contains("landed") || s.contains("arrived") { return .landed }
        if s.contains("delayed") { return .delayed }
        if s.contains("taxi") || s.contains("departed") { return .departed }
        return .unknown
    }
}

struct AeroAirport: Decodable {
    let code: String?
    let codeIata: String?

    enum CodingKeys: String, CodingKey {
        case code
        case codeIata = "code_iata"
    }

    var iata: String? { codeIata ?? code }
}
