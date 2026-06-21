import Foundation
import Amplify

/// Helpers to read Amplify's `JSONValue` and to map to/from our domain models.
/// Using JSONValue keeps the repository compiling before model codegen runs.
extension JSONValue {
    /// Dotted-path lookup, e.g. `value(at: "listFlights.items")`.
    func value(at path: String) -> JSONValue? {
        var current: JSONValue? = self
        for key in path.split(separator: ".") {
            guard case let .object(obj)? = current else { return nil }
            current = obj[String(key)]
        }
        return current
    }

    var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case let .number(n) = self { return Int(n) }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    var dateValue: Date? {
        guard let s = stringValue else { return nil }
        return ISO8601DateFormatter.flexible.date(from: s)
    }
}

extension ISO8601DateFormatter {
    /// AeroAPI / AppSync may or may not include fractional seconds.
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - JSONValue -> domain

extension JSONValue {
    var asUserProfile: UserProfile? {
        guard let id = value(at: "id")?.stringValue,
              let name = value(at: "displayName")?.stringValue,
              let email = value(at: "email")?.stringValue else { return nil }
        return UserProfile(
            id: id, displayName: name, email: email,
            homeAirport: value(at: "homeAirport")?.stringValue
        )
    }

    var asFlightLookupResult: FlightLookupResult? {
        guard let number = value(at: "flightNumber")?.stringValue else { return nil }
        let statusStr = value(at: "status")?.stringValue ?? "UNKNOWN"
        var cached = false
        if case let .boolean(b)? = self.value(at: "cached") { cached = b }
        return FlightLookupResult(
            flightNumber: number,
            faFlightId: value(at: "faFlightId")?.stringValue,
            status: FlightStatus(rawValue: statusStr) ?? .unknown,
            originIata: value(at: "originIata")?.stringValue,
            destinationIata: value(at: "destinationIata")?.stringValue,
            scheduledOut: value(at: "scheduledOut")?.dateValue,
            scheduledIn: value(at: "scheduledIn")?.dateValue,
            estimatedOut: value(at: "estimatedOut")?.dateValue,
            estimatedIn: value(at: "estimatedIn")?.dateValue,
            actualOut: value(at: "actualOut")?.dateValue,
            actualIn: value(at: "actualIn")?.dateValue,
            originGate: value(at: "originGate")?.stringValue,
            destinationGate: value(at: "destinationGate")?.stringValue,
            originTerminal: value(at: "originTerminal")?.stringValue,
            destinationTerminal: value(at: "destinationTerminal")?.stringValue,
            progressPercent: value(at: "progressPercent")?.intValue,
            cached: cached
        )
    }

    var asFlight: Flight? {
        guard let id = value(at: "id")?.stringValue,
              let profileId = value(at: "profileId")?.stringValue,
              let number = value(at: "flightNumber")?.stringValue,
              let origin = value(at: "originIata")?.stringValue,
              let dest = value(at: "destinationIata")?.stringValue else { return nil }

        let dateStr = value(at: "departureDate")?.stringValue ?? ""
        let depDate = DateOnly.parse(dateStr) ?? Date()
        let statusStr = value(at: "status")?.stringValue ?? "UNKNOWN"

        return Flight(
            id: id,
            profileId: profileId,
            ownerEmail: value(at: "ownerEmail")?.stringValue,
            viewers: value(at: "viewers")?.arrayValue?.compactMap { $0.stringValue },
            flightNumber: number,
            faFlightId: value(at: "faFlightId")?.stringValue,
            departureDate: depDate,
            originIata: origin,
            destinationIata: dest,
            scheduledOut: value(at: "scheduledOut")?.dateValue,
            scheduledIn: value(at: "scheduledIn")?.dateValue,
            estimatedOut: value(at: "estimatedOut")?.dateValue,
            estimatedIn: value(at: "estimatedIn")?.dateValue,
            actualOut: value(at: "actualOut")?.dateValue,
            actualIn: value(at: "actualIn")?.dateValue,
            status: FlightStatus(rawValue: statusStr) ?? .unknown,
            originGate: value(at: "originGate")?.stringValue,
            destinationGate: value(at: "destinationGate")?.stringValue,
            originTerminal: value(at: "originTerminal")?.stringValue,
            destinationTerminal: value(at: "destinationTerminal")?.stringValue,
            progressPercent: value(at: "progressPercent")?.intValue,
            lastRefreshedAt: value(at: "lastRefreshedAt")?.dateValue,
            note: value(at: "note")?.stringValue
        )
    }
}

// MARK: - domain -> GraphQL input

extension Flight {
    var createInput: [String: Any] {
        var dict = baseInput
        // createFlight does not take an id (AppSync generates it) unless you want
        // to set one; we let the backend assign.
        return dict.compactMapValues { $0 }
    }

    var updateInput: [String: Any] {
        var dict = baseInput
        dict["id"] = id
        return dict.compactMapValues { $0 }
    }

    /// Variables for the custom `publishFlightUpdate` mutation: id + the mutable
    /// live-status fields, as individual arguments (not an input object). Nils
    /// are dropped so the resolver does a partial update.
    var publishUpdateVars: [String: Any] {
        let iso = ISO8601DateFormatter.flexible
        let vars: [String: Any?] = [
            "id": id,
            "status": status.rawValue,
            "estimatedOut": estimatedOut.map(iso.string),
            "estimatedIn": estimatedIn.map(iso.string),
            "actualOut": actualOut.map(iso.string),
            "actualIn": actualIn.map(iso.string),
            "originGate": originGate,
            "destinationGate": destinationGate,
            "originTerminal": originTerminal,
            "destinationTerminal": destinationTerminal,
            "progressPercent": progressPercent,
            "lastRefreshedAt": lastRefreshedAt.map(iso.string),
            "note": note,
        ]
        return vars.compactMapValues { $0 }
    }

    private var baseInput: [String: Any?] {
        let iso = ISO8601DateFormatter.flexible
        return [
            "profileId": profileId,
            "ownerEmail": ownerEmail,
            "viewers": viewers,
            "flightNumber": flightNumber,
            "faFlightId": faFlightId,
            "departureDate": DateOnly.string(departureDate),
            "originIata": originIata,
            "destinationIata": destinationIata,
            "scheduledOut": scheduledOut.map(iso.string),
            "scheduledIn": scheduledIn.map(iso.string),
            "estimatedOut": estimatedOut.map(iso.string),
            "estimatedIn": estimatedIn.map(iso.string),
            "actualOut": actualOut.map(iso.string),
            "actualIn": actualIn.map(iso.string),
            "status": status.rawValue,
            "originGate": originGate,
            "destinationGate": destinationGate,
            "originTerminal": originTerminal,
            "destinationTerminal": destinationTerminal,
            "progressPercent": progressPercent,
            "lastRefreshedAt": lastRefreshedAt.map(iso.string),
            "note": note,
        ]
    }
}

/// AppSync `AWSDate` is `YYYY-MM-DD`.
enum DateOnly {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
    static func parse(_ s: String) -> Date? { formatter.date(from: s) }
}
