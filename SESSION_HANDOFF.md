# FlightTrack — Session Handoff

Paste this into a new session to continue. Repo: `/Users/jackroberts/git/filght-track`
(note the dir typo "filght"). GitHub: `https://github.com/jroberts64/flight-track` (public).

## What this is
Native **SwiftUI** iPhone app to track your flights, share them with family, and see
theirs. Live flight data from **FlightAware AeroAPI**; backend on **AWS Amplify Gen 2**
(Cognito auth, AppSync/DynamoDB, SNS push). Personal project for Jack + family.

## ✅ WORKING END-TO-END (verified on a physical device)
Sign in → My Flights loads → add a flight (live AeroAPI lookup, gates/status) →
scheduled Lambda detects a change → SNS/APNs **push delivered to the iPhone**. Auth,
profile creation, flight persistence, and push all confirmed live.

## Current state
- **Backend:** deployed to AWS account `019135476568`, region `us-east-1`, as an `ampx`
  **sandbox** (NOT a pipeline/branch deploy yet). Cognito user pool, all model tables,
  AeroAPI proxy Lambda + cache, scheduled flight-refresh Lambda, SNS APNs platform app
  (`APNS_SANDBOX`), and the pre-token-generation trigger are all live.
- **iOS:** Xcode project at `FlightTrack.xcodeproj` (repo root), sources in `FlightTrack/`
  (synchronized file group — new `.swift` files auto-included). Bundle ID
  `com.jack-roberts.flighttrack`. Builds + runs on device. iOS 17+ deployment target.
  Requires the iOS 26.5 simulator runtime for sim builds.
- **Push:** enabled. APNs `.p8` key + env in `~/.apple-developer/` (key id `L5TS25Z2T5`,
  team `V65ZGC2KRW`). `~/.apple-developer/flighttrack.env` holds the deploy vars
  (`ENABLE_PUSH=true`, `APNS_SANDBOX=true`, etc.).
- **Email:** Cognito currently uses its DEFAULT sender (spam-prone) — the custom SES
  sender is NOT wired in (see cleanup #1). SES production access was APPROVED.

## How to operate (key commands)
```bash
# AWS auth (SSO token expires often — re-run when ampx says "Token is expired"):
aws sso login --sso-session personal-sso
export AWS_PROFILE=personal-sso

# Deploy backend (source the APNs env so push stays provisioned; do NOT set
# COGNITO_SENDER_EMAIL yet — it wedges the stack, see cleanup #1):
source ~/.apple-developer/flighttrack.env
unset COGNITO_SENDER_EMAIL COGNITO_SENDER_NAME
AWS_PROFILE=personal-sso npx ampx sandbox --once

# IMPORTANT after every deploy: ampx writes amplify_outputs.json to the REPO ROOT,
# but the app reads FlightTrack/amplify_outputs.json — sync it:
cp amplify_outputs.json FlightTrack/amplify_outputs.json

# Build to simulator (device builds you do via Xcode ⌘R):
SIMID=$(xcrun simctl list devices "iOS 26.5" | grep "iPhone 16 Pro (" | grep -oE "[0-9A-F-]{36}" | head -1)
xcodebuild -project FlightTrack.xcodeproj -scheme FlightTrack -destination "id=$SIMID" -derivedDataPath /tmp/ft-derived build
```

`gh` has two accounts; pushes need `gh auth switch --user jroberts64` first (the active
default `jroberts-juicerpricing` lacks write access → 403).

## Test account
`roberts@pnut.com` / `DebugTest9$x` (a debug password I set — CONFIRMED, email_verified).
Pool/client IDs change on every delete+redeploy; read them from
`FlightTrack/amplify_outputs.json`.

## Cleanup owed (small, non-blocking)
1. **Re-add custom SES sender.** `no-reply@jack-roberts.com` IS now a verified SES email
   identity. Deploy with `COGNITO_SENDER_EMAIL="no-reply@jack-roberts.com"` set —
   SEPARATELY, so if it wedges the auth stack it doesn't block other work. Cognito needs
   the exact from-address as its own verified identity (a verified domain alone is NOT
   enough — this caused repeated UPDATE_ROLLBACK_FAILED last session).
2. **Change the debug password** off `DebugTest9$x`.
3. **Revert test tweak:** I manually cleared flight DL5435's `originGate` + set a fake
   `scheduledOut` to force the test push. A real refresh corrects it; or restore cleanly.

## Bigger remaining work
- **Family sharing: built + deployed but NEVER tested with two real accounts.** Needs a
  2nd account (can admin-create one via CLI). Cross-family reads use a `viewers[]` list
  on Flight + `ownersDefinedIn`, maintained by `FamilyViewModel.reconcileMyViewers()` on
  family-screen load. Known limitation: owner-scoped subscriptions mean family flight
  updates are NOT live in-app (load/refresh + push only).
- **Edge case:** flights AeroAPI returns with no resolved departure time fall outside the
  refresh window (skipped) until a time is known. Real fully-scheduled flights are fine.
- Not yet: a real CI/branch deploy (OIDC role + workflow exist in `deploy/` +
  `.github/workflows/deploy-backend.yml`), App Store/TestFlight (would need
  `APNS_SANDBOX=false` prod APNs).

## Read these in the repo
- `CLAUDE.md` — architecture, data model, conventions, layout.
- `README.md` — setup, push enablement, SES, hardening checklist.
- `FlightTrack/Config/SETUP.md` — Xcode/build details.
- Memory dir has `amplify-gotchas.md` — the hard-won Amplify Gen 2 footguns from last
  session (access-token email claim, circular deps, GSI grants, Cognito SES, wedged-stack
  recovery). Read it before touching auth/SES/push wiring.

## Architecture quick map
- `amplify/auth/` — Cognito + pre-token-generation trigger (injects `email` into the
  ACCESS token; required because AppSync owner rules match `identityClaim('email')` and
  the access token otherwise lacks it).
- `amplify/data/resource.ts` — UserProfile, Flight (ownerEmail + viewers[]), FamilyLink,
  DeviceToken; `lookupFlight` custom query.
- `amplify/functions/aeroapi-lookup/` — AeroAPI proxy (key = Amplify secret, cached in
  DynamoDB). `resourceGroupName: 'data'` to avoid circular dep.
- `amplify/functions/flight-refresh/` — scheduled 30m; diffs flights, pushes via SNS,
  mints SNS endpoints lazily.
- `FlightTrack/Services/GraphQLAuth.swift` — `GQL.userPool(...)` pins the Cognito
  user-pool auth mode on every request (raw GraphQLRequest defaults authMode to nil).
