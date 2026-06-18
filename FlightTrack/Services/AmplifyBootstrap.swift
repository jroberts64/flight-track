import Foundation
import Amplify
import AWSCognitoAuthPlugin
import AWSAPIPlugin

/// Configures Amplify once at app launch. Call `AmplifyBootstrap.configure()`
/// from the App's init.
enum AmplifyBootstrap {
    private static var configured = false

    static func configure() {
        guard !configured else { return }
        do {
            try Amplify.add(plugin: AWSCognitoAuthPlugin())
            try Amplify.add(plugin: AWSAPIPlugin())
            // Amplify Gen 2 reads `amplify_outputs.json` bundled in the app.
            try Amplify.configure(with: .amplifyOutputs)
            configured = true
            Amplify.log.info("Amplify configured")
        } catch {
            assertionFailure("Failed to configure Amplify: \(error)")
        }
    }
}
