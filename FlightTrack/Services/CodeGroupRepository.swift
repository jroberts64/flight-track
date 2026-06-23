import Foundation
import Combine
import Amplify

/// Persistence for code-sharing groups and service links (the "Codes" feature).
///
/// Kept separate from `FlightRepository` (one domain per repo). Uses the same
/// hand-written-GraphQL + `GQL.userPool(...)` style so it compiles before
/// codegen. Groups/links use the GENERATED CRUD mutations — unlike flights,
/// there's no live cross-account subscription (delivery is push), so the simple
/// generated mutations are enough.
@MainActor
final class CodeGroupRepository: ObservableObject {
    static let shared = CodeGroupRepository()

    private static let groupFields = "id ownerEmail name memberEmails"
    private static let linkFields = "id ownerEmail groupId serviceName matchRules enabled"

    // MARK: Groups

    func listMyGroups(ownerEmail: String) async throws -> [CodeGroup] {
        let doc = """
        query List($owner: String!) {
          listCodeGroups(filter: { ownerEmail: { eq: $owner } }) {
            items { \(Self.groupFields) }
          }
        }
        """
        let json = try await queryTolerant(doc, ["owner": ownerEmail.lowercased()])
        let items = json.value(at: "listCodeGroups.items")?.arrayValue ?? []
        return items.compactMap { $0.asCodeGroup }.sorted { $0.name < $1.name }
    }

    func createGroup(ownerEmail: String, name: String, members: [String]) async throws -> CodeGroup {
        let doc = """
        mutation Create($input: CreateCodeGroupInput!) {
          createCodeGroup(input: $input) { \(Self.groupFields) }
        }
        """
        let input: [String: Any] = [
            "ownerEmail": ownerEmail.lowercased(),
            "name": name,
            "memberEmails": members.map { $0.lowercased() },
        ]
        let result: GraphQLResponse<JSONValue> = try await Amplify.API.mutate(
            request: GQL.userPool(doc, variables: ["input": input])
        )
        guard let created = try result.get().value(at: "createCodeGroup")?.asCodeGroup else {
            throw RepoError.malformedResponse
        }
        return created
    }

    func updateGroupMembers(id: String, name: String, members: [String]) async throws {
        let doc = """
        mutation Update($input: UpdateCodeGroupInput!) {
          updateCodeGroup(input: $input) { \(Self.groupFields) }
        }
        """
        let input: [String: Any] = [
            "id": id,
            "name": name,
            "memberEmails": members.map { $0.lowercased() },
        ]
        _ = try await Amplify.API.mutate(request: GQL.userPool(doc, variables: ["input": input]))
    }

    func deleteGroup(id: String) async throws {
        let doc = """
        mutation Delete($input: DeleteCodeGroupInput!) {
          deleteCodeGroup(input: $input) { id }
        }
        """
        _ = try await Amplify.API.mutate(request: GQL.userPool(doc, variables: ["input": ["id": id]]))
    }

    // MARK: Service links

    func listMyServiceLinks(ownerEmail: String) async throws -> [ServiceLink] {
        let doc = """
        query List($owner: String!) {
          listServiceLinks(filter: { ownerEmail: { eq: $owner } }) {
            items { \(Self.linkFields) }
          }
        }
        """
        let json = try await queryTolerant(doc, ["owner": ownerEmail.lowercased()])
        let items = json.value(at: "listServiceLinks.items")?.arrayValue ?? []
        return items.compactMap { $0.asServiceLink }.sorted { $0.serviceName < $1.serviceName }
    }

    func createServiceLink(
        ownerEmail: String,
        groupId: String,
        serviceName: String,
        matchRules: String
    ) async throws -> ServiceLink {
        let doc = """
        mutation Create($input: CreateServiceLinkInput!) {
          createServiceLink(input: $input) { \(Self.linkFields) }
        }
        """
        let input: [String: Any] = [
            "ownerEmail": ownerEmail.lowercased(),
            "groupId": groupId,
            "serviceName": serviceName,
            "matchRules": matchRules,
            "enabled": true,
        ]
        let result: GraphQLResponse<JSONValue> = try await Amplify.API.mutate(
            request: GQL.userPool(doc, variables: ["input": input])
        )
        guard let created = try result.get().value(at: "createServiceLink")?.asServiceLink else {
            throw RepoError.malformedResponse
        }
        return created
    }

    func deleteServiceLink(id: String) async throws {
        let doc = """
        mutation Delete($input: DeleteServiceLinkInput!) {
          deleteServiceLink(input: $input) { id }
        }
        """
        _ = try await Amplify.API.mutate(request: GQL.userPool(doc, variables: ["input": ["id": id]]))
    }

    // MARK: Helpers

    /// Runs a list query tolerating partial responses (data + per-item field
    /// errors), mirroring `FlightRepository.listMyFlights`.
    private func queryTolerant(_ doc: String, _ vars: [String: Any]) async throws -> JSONValue {
        let result: GraphQLResponse<JSONValue> = try await Amplify.API.query(
            request: GQL.userPool(doc, variables: vars)
        )
        switch result {
        case .success(let value):
            return value
        case .failure(let responseError):
            switch responseError {
            case .partial(let value, _):
                return value
            case .error(let errors):
                throw RepoError.graphQL(errors.first?.message ?? "Query failed")
            case .transformationError:
                throw RepoError.malformedResponse
            @unknown default:
                throw RepoError.malformedResponse
            }
        }
    }
}
