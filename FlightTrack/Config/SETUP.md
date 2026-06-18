# Xcode project

The project already exists: `filght-track/FlightTrack.xcodeproj`, with sources in
`filght-track/FlightTrack/` (groups: `AppCore`, `Models`, `Services`, `ViewModels`,
`Views`). It uses a **synchronized file group**, so any `.swift` added under
`FlightTrack/` is picked up automatically — no manual "Add Files" step.

Key project settings already applied:
- `IPHONEOS_DEPLOYMENT_TARGET = 17.0`
- Amplify Swift package added with products `Amplify`, `AWSCognitoAuthPlugin`,
  `AWSAPIPlugin`.
- `FlightTrack/amplify_outputs.json` is in the source dir (gitignored) so the bundle
  picks it up; `Amplify.configure(with: .amplifyOutputs)` reads it at launch.

## Build / run
Open `FlightTrack.xcodeproj` and ⌘R on a simulator, or from the CLI:
```bash
SIMID=$(xcrun simctl list devices "iOS 26.5" | grep "iPhone 16 Pro (" | grep -oE "[0-9A-F-]{36}" | head -1)
xcodebuild -project FlightTrack.xcodeproj -scheme FlightTrack \
  -destination "id=$SIMID" build
```
Requires the iOS 26.5 simulator runtime (`xcodebuild -downloadPlatform iOS`).

## Re-adding the Amplify package (only if the project is ever recreated)
File → Add Package Dependencies → `https://github.com/aws-amplify/amplify-swift`
Add to the FlightTrack target: `Amplify`, `AWSCognitoAuthPlugin`, `AWSAPIPlugin`.

## 4. Generate the backend + outputs
From the repo root in Terminal. This account uses AWS SSO:
```bash
aws sso login --sso-session personal-sso
export AWS_PROFILE=personal-sso        # account 019135476568, us-east-1
npm install
npx ampx sandbox
```
This writes `amplify_outputs.json` to the repo root. Drag that file into the Xcode
project (target: FlightTrack, "Copy if needed"). `Amplify.configure(with: .amplifyOutputs)`
will pick it up.

## 5. AeroAPI key (server-side — NOT in the app)
The app never holds the AeroAPI key. It's stored as an Amplify secret and used only
by the `aeroapi-lookup` Lambda. The iOS client calls the `lookupFlight` backend query.

Set the secret once (after signing up at flightaware.com/aeroapi/portal/ for a key):
```bash
npx ampx sandbox secret set AERO_API_KEY
# paste the key when prompted
```
For a deployed branch, set it via the Amplify console (App settings → Secrets) or
`npx ampx pipeline-deploy` and the console.

## 6. Run
Pick a simulator and ⌘R. Create an account, confirm via the emailed code, sign in,
add a flight by number, then invite a family member by their account email from the
Family tab.
```
```
