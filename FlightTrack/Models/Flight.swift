import Foundation

/// Domain model used throughout the UI. This is decoupled from the Amplify
/// generated model so views never depend on backend codegen details.
struct Flight: Identifiable, Hashable, Codable {
    var id: String
    var profileId: String
    /// Denormalized owner email — owner-auth identifier + lets the backend
    /// refresh/notify without a join.
    var ownerEmail: String?
    /// Emails allowed to read this flight: owner + accepted connections.
    var viewers: [String]?

    var flightNumber: String
    var faFlightId: String?

    var departureDate: Date          // local departure date (midnight UTC of that day)
    var originIata: String
    var destinationIata: String

    var scheduledOut: Date?
    var scheduledIn: Date?
    var estimatedOut: Date?
    var estimatedIn: Date?
    var actualOut: Date?
    var actualIn: Date?

    var status: FlightStatus
    var originGate: String?
    var destinationGate: String?
    var originTerminal: String?
    var destinationTerminal: String?
    var progressPercent: Int?
    var lastRefreshedAt: Date?

    var note: String?

    /// The best available departure time: actual > estimated > scheduled.
    var effectiveDeparture: Date? { actualOut ?? estimatedOut ?? scheduledOut }
    var effectiveArrival: Date? { actualIn ?? estimatedIn ?? scheduledIn }

    /// True only while the flight is still expected to run late. A completed
    /// flight (terminal status, or one that already has an actual departure or
    /// arrival) is never "delayed" — its estimate is moot, so the badge shows the
    /// real status instead. Threshold matches the backend notification gate.
    var isDelayed: Bool {
        // Done flying: show the actual status, not a stale delay.
        if status == .landed || status == .cancelled || status == .diverted { return false }
        if actualIn != nil { return false }
        guard let sched = scheduledOut, let est = estimatedOut else { return status == .delayed }
        return est.timeIntervalSince(sched) > Flight.delayThreshold
    }

    /// Estimated time must slip at least this far past schedule to read as delayed.
    /// Mirrors the refresh Lambda's DELAY_THRESHOLD_MIN (default 10 min).
    static let delayThreshold: TimeInterval = 10 * 60
}

enum FlightStatus: String, Codable, CaseIterable {
    case scheduled = "SCHEDULED"
    case boarding = "BOARDING"
    case departed = "DEPARTED"
    case enroute = "ENROUTE"
    case landed = "LANDED"
    case cancelled = "CANCELLED"
    case delayed = "DELAYED"
    case diverted = "DIVERTED"
    case unknown = "UNKNOWN"

    var label: String {
        switch self {
        case .scheduled: return "Scheduled"
        case .boarding: return "Boarding"
        case .departed: return "Departed"
        case .enroute: return "En route"
        case .landed: return "Landed"
        case .cancelled: return "Cancelled"
        case .delayed: return "Delayed"
        case .diverted: return "Diverted"
        case .unknown: return "Unknown"
        }
    }
}
