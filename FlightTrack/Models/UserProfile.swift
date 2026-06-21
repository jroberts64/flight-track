import Foundation

struct UserProfile: Identifiable, Hashable, Codable {
    var id: String
    var displayName: String
    var email: String
    var homeAirport: String?
}

enum LinkStatus: String, Codable {
    case pending = "PENDING"
    case accepted = "ACCEPTED"
    case declined = "DECLINED"
}

/// A connection between two accounts (family or friend). When
/// `status == .accepted` the two users may view each other's flights.
struct Connection: Identifiable, Hashable, Codable {
    var id: String
    var inviterEmail: String
    var inviteeEmail: String
    var status: LinkStatus

    /// Given the current user's email, returns the other party's email.
    func counterparty(for myEmail: String) -> String {
        inviterEmail.caseInsensitiveCompare(myEmail) == .orderedSame ? inviteeEmail : inviterEmail
    }

    func isInvitee(_ myEmail: String) -> Bool {
        inviteeEmail.caseInsensitiveCompare(myEmail) == .orderedSame
    }
}
