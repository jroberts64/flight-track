# Creating the Xcode project

These Swift sources aren't yet wrapped in an `.xcodeproj` (Xcode projects are binary
and best generated on your Mac). Here's the 10-minute path to a running app.

## 1. Create the project
1. Xcode → File → New → Project → iOS → App.
2. Product Name: **FlightTrack**, Interface: **SwiftUI**, Language: **Swift**,
   minimum deployment **iOS 17.0**.
3. Save it inside this repo root (so the folder is `filght-track/FlightTrack.xcodeproj`).
4. Delete the auto-generated `ContentView.swift` and the default `*App.swift` — you'll use
   the ones in `FlightTrack/App/`.

## 2. Add the sources
In Xcode, right-click the project → "Add Files to FlightTrack…" and add the
`FlightTrack/App`, `Models`, `Services`, `ViewModels`, and `Views` folders
(choose "Create groups").

## 3. Add Amplify Swift
File → Add Package Dependencies → `https://github.com/aws-amplify/amplify-swift`
Add these products to the FlightTrack target:
- `Amplify`
- `AWSCognitoAuthPlugin`
- `AWSAPIPlugin`

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

## 5. AeroAPI key (dev)
1. Copy `Config/Secrets.example.xcconfig` → `Config/Secrets.xcconfig`, paste your key.
2. Project → Info → Configurations → set Debug & Release to `Secrets.xcconfig`.
3. In `Info.plist`, add row `AERO_API_KEY` = `$(AERO_API_KEY)`.

## 6. Run
Pick a simulator and ⌘R. Create an account, confirm via the emailed code, sign in,
add a flight by number, then invite a family member by their account email from the
Family tab.
```
```
