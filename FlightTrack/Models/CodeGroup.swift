import Foundation

/// A named group of connections that receive shared service codes (e.g.
/// "Family"). Owner-created from accepted connections; the owner links services
/// to it and members receive code pushes. Mirrors the backend CodeGroup model.
struct CodeGroup: Identifiable, Hashable, Codable {
    var id: String
    var ownerEmail: String
    var name: String
    var memberEmails: [String]
}

/// Maps a service (HBO Max, Netflix, …) to a CodeGroup plus the rules used to
/// recognize that service's code emails. `matchRules` is JSON:
/// `{ "fromContains": "...", "subjectContains": "...", "codeRegex": "..." }`.
struct ServiceLink: Identifiable, Hashable, Codable {
    var id: String
    var ownerEmail: String
    var groupId: String
    var serviceName: String
    var matchRules: String?
    var enabled: Bool
}

/// An ephemeral code delivered via push (built from the notification payload,
/// not persisted in the app). Shown transiently in the UI after a push.
struct CodeEvent: Hashable {
    var service: String
    var group: String
    var code: String
    var receivedAt: Date
}

/// Built-in service presets for the "add service" picker. Each carries default
/// match rules so the user usually just picks a service. The "Custom" case lets
/// advanced users author their own rules. Keep the rule JSON shape in sync with
/// the email-ingest Lambda's MatchRules (fromContains / subjectContains / codeRegex).
struct ServicePreset: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var matchRules: String

    static let presets: [ServicePreset] = [
        ServicePreset(
            name: "HBO Max",
            matchRules: #"{"fromContains":"hbomax.com","subjectContains":"code","codeRegex":"\\b(\\d{4,8})\\b"}"#
        ),
        ServicePreset(
            name: "Netflix",
            matchRules: #"{"fromContains":"netflix.com","subjectContains":"code","codeRegex":"\\b(\\d{4,8})\\b"}"#
        ),
        ServicePreset(
            name: "Disney+",
            matchRules: #"{"fromContains":"disneyplus.com","subjectContains":"code","codeRegex":"\\b(\\d{4,8})\\b"}"#
        ),
        ServicePreset(
            name: "Hulu",
            matchRules: #"{"fromContains":"hulu.com","subjectContains":"code","codeRegex":"\\b(\\d{4,8})\\b"}"#
        ),
    ]
}
