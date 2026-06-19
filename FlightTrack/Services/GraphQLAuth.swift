import Foundation
import Amplify
import AWSPluginsCore

/// Builds GraphQLRequests with the Cognito user-pool auth mode pinned.
///
/// Why this exists: when a GraphQLRequest is built from a raw document + a
/// `responseType` (as this app does, rather than from generated models), its
/// `authMode` defaults to `nil`. The AWSAPIPlugin does not reliably fall back to
/// the configured default user-pool mode for raw requests, so it can send the
/// request without the Cognito token — and owner/ownersDefinedIn rules then
/// reject it with "Not Authorized to access <op> on type Query/Mutation".
///
/// Pinning `.amazonCognitoUserPools` on every request guarantees the ID token is
/// attached so owner-based authorization resolves.
enum GQL {
    static func userPool(
        _ document: String,
        variables: [String: Any]? = nil
    ) -> GraphQLRequest<JSONValue> {
        GraphQLRequest(
            document: document,
            variables: variables,
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )
    }
}
