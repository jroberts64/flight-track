import Foundation

/// Result of the backend `lookupFlight` query (see amplify/functions/aeroapi-lookup).
/// The iOS app never talks to FlightAware directly — this mirrors the Lambda's
/// normalized `FlightLookupResult` custom type. All datetimes are ISO 8601 strings.
struct FlightLookupResult {
    let flightNumber: String
    let faFlightId: String?
    let status: FlightStatus
    let originIata: String?
    let destinationIata: String?
    let scheduledOut: Date?
    let scheduledIn: Date?
    let estimatedOut: Date?
    let estimatedIn: Date?
    let actualOut: Date?
    let actualIn: Date?
    let originGate: String?
    let destinationGate: String?
    let originTerminal: String?
    let destinationTerminal: String?
    let progressPercent: Int?
    let cached: Bool

    /// Applies this live snapshot onto an existing Flight.
    func apply(to flight: inout Flight) {
        flight.faFlightId = faFlightId ?? flight.faFlightId
        flight.status = status
        flight.progressPercent = progressPercent ?? flight.progressPercent
        flight.scheduledOut = scheduledOut ?? flight.scheduledOut
        flight.scheduledIn = scheduledIn ?? flight.scheduledIn
        flight.estimatedOut = estimatedOut ?? flight.estimatedOut
        flight.estimatedIn = estimatedIn ?? flight.estimatedIn
        flight.actualOut = actualOut ?? flight.actualOut
        flight.actualIn = actualIn ?? flight.actualIn
        flight.originGate = originGate ?? flight.originGate
        flight.destinationGate = destinationGate ?? flight.destinationGate
        flight.originTerminal = originTerminal ?? flight.originTerminal
        flight.destinationTerminal = destinationTerminal ?? flight.destinationTerminal
        if let iata = originIata, !iata.isEmpty { flight.originIata = iata }
        if let iata = destinationIata, !iata.isEmpty { flight.destinationIata = iata }
        flight.lastRefreshedAt = Date()
    }
}
