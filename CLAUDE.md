# CLAUDE.md

Guidance for working in this repo. Read alongside `README.md` (user-facing setup) and
`FlightTrack/Config/SETUP.md` (Xcode project creation).

## What this is

**FlightTrack** — an iPhone app to track your flights, share them with family, and see
your family's flights. Live flight status comes from FlightAware AeroAPI; accounts and
real-time family sync run on AWS Amplify Gen 2.

> The directory name is `filght-track` (typo). The GitHub repo and product name are
> `flight-track` / FlightTrack.

## Stack

| Layer       | Choice                                                       |
|-------------|--------------------------------------------------------------|
| iOS app     | Native Swift / SwiftUI (iOS 17+)                             |
| Auth        | AWS Cognito (Amplify Gen 2)                                  |
| Data + sync | AWS AppSync (GraphQL real-time) + DynamoDB                   |
| Flight data | FlightAware AeroAPI                                          |
| Backend lang| TypeScript (Amplify Gen 2 `amplify/`)                        |

## Repository layout

| Path | Responsibility |
|------|----------------|
| `amplify/auth/resource.ts` | Cognito config (email sign-in). |
| `amplify/data/resource.ts` | Data model + authorization: `UserProfile`, `Flight`, `Connection`. Single source of truth for the backend schema. |
| `amplify/backend.ts` | Backend entrypoint: wires auth + data + the AeroAPI Lambda, and provisions the DynamoDB cache table (TTL) granted to the Lambda. |
| `amplify/functions/aeroapi-lookup/` | Lambda that proxies FlightAware AeroAPI server-side (key as an Amplify secret) with a DynamoDB cache. Exposed as the `lookupFlight` AppSync query. Pinned to the **data** stack (`resourceGroupName: 'data'`) to avoid a circular dependency. |
| `amplify/functions/flight-refresh/` | Scheduled (30m) Lambda. Refreshes near-window flights via AeroAPI, diffs, updates, and pushes change alerts via SNS. Creates SNS endpoints lazily. |
| `FlightTrack/App/` | App entrypoint (`FlightTrackApp`), `AppDelegate` (APNs token via `@UIApplicationDelegateAdaptor`), `RootView` (auth gate + tabs), `SessionStore` (per-session identity + profile id; sets push owner email). |
| `FlightTrack/Models/` | Domain models (`Flight`/`FlightStatus`, `UserProfile`/`Connection`) + AeroAPI decodables. Decoupled from Amplify codegen on purpose. |
| `FlightTrack/Services/` | `AmplifyBootstrap`, `AuthService` (Cognito), `FlightRepository` (GraphQL CRUD + real-time subscription), `AeroAPIClient` (calls the `lookupFlight` backend query — NOT FlightAware directly), `PushService` (APNs permission + writes a DeviceToken row), `JSONMapping` (JSONValue ↔ domain). |
| `FlightTrack/ViewModels/` | `FlightsViewModel`, `ConnectionsViewModel`. |
| `FlightTrack/Views/` | SwiftUI screens: auth, my-flights + add-flight, connections, flight row. |
| `FlightTrack/Config/` | `SETUP.md` (Xcode project creation + secret setup). |
| `deploy/` | `github-oidc.yaml` (CI deploy role), `bootstrap-oidc.sh` (one-time role create). |
| `.github/workflows/deploy-backend.yml` | CI: `ampx pipeline-deploy` on push to main via OIDC. |

## AWS access

Account **`019135476568`**, region **`us-east-1`**.

- **Local:** `aws sso login --sso-session personal-sso` then `export AWS_PROFILE=personal-sso`.
- **CI:** GitHub Actions OIDC — no stored secrets. The OIDC provider is account-wide and
  already exists (created by the `bin-builder` repo); `github-oidc.yaml` reuses it
  (`CreateOIDCProvider=false`) and adds a repo+branch-scoped role.

## Commands

```bash
npm install
npx ampx sandbox        # deploy a personal backend sandbox + write amplify_outputs.json
npx ampx sandbox --once # single deploy, no file watching
```

There is **no Swift test suite or linter** configured, and no `.xcodeproj` is committed —
Xcode projects are binary and generated locally (see `FlightTrack/Config/SETUP.md`).
The Swift sources have **never been compiled in CI**; treat the first Xcode build as a
shakeout. "Verify" the backend means: `npx ampx sandbox --once` deploys clean.

## Data model + authorization

- **UserProfile** — one per account (displayName, email, optional homeAirport). Owner
  has full CRUD; any authenticated user can *read* (so you can find people by email).
- **Flight** — owned by one user; cached AeroAPI snapshot (status, gates, terminals,
  times, progress). Owner auth is `ownerDefinedIn('ownerEmail')` (matched on the email
  claim), so `ownerEmail` is **required** and doubles as the push-recipient key.
  Cross-account read is granted by `viewers: [String]` via
  `ownersDefinedIn('viewers').to(['read'])` — the list holds the owner + accepted
  connection emails.
- **Connection** — directed invite (inviterEmail → inviteeEmail) with status
  PENDING/ACCEPTED/DECLINED, between two accounts (family or friend). When ACCEPTED,
  the app loads the counterparty's flights. (Renamed from `FamilyLink`.)
- **DeviceToken** — one per device (ownerEmail, APNs token, snsEndpointArn, platform).
  Owner-writable; the app creates it, the refresh Lambda fills in `snsEndpointArn`
  lazily. GSI on `ownerEmail` (`deviceTokensByOwnerEmail`) for recipient lookup.

**Cross-account read = the `viewers` list.** Each user maintains their OWN flights'
viewers (owner auth prevents touching others'). `ConnectionsViewModel.reconcileMyViewers()`
rewrites my flights' viewers to (me + my accepted connections) on every connections-screen
load, and `FlightsViewModel.addFlight` sets it on create. Both sides converge regardless of
who accepted when — this is the drift-mitigation for the per-row-list approach (Option A).
`FlightRepository.refreshViewers` / `acceptedConnectionEmails` are the single source of truth.
NOTE: cross-account visibility requires the flight OWNER to run reconcile (open the
Connections screen) after acceptance — see memory `family-sharing-verified`.

**Lambda ↔ data access:** the push Lambdas read/write model tables via **direct
DynamoDB IAM grants** in `backend.ts` (not the data client). A function bound as an
AppSync resolver (e.g. `aeroapi-lookup`) must set `resourceGroupName: 'data'` or it
creates a circular dependency between the data and function nested stacks.

## Conventions

- Keep the four Amplify runtime concerns in their `resource.ts` files; don't scatter
  schema definitions.
- Swift domain models are deliberately separate from Amplify's generated types — views
  and view models depend only on `FlightTrack/Models`, and `JSONMapping.swift` bridges
  to GraphQL. Keep that boundary.
- GraphQL documents in `FlightRepository`/`ConnectionsViewModel` are hand-written so the app
  compiles before codegen runs. The shared flight field set lives in
  `FlightRepository.flightFields` — update it in one place.
- `@MainActor` on services/view models that publish to the UI; async work via
  `Task { ... }` from views.

## Secrets

- The AeroAPI key is an **Amplify secret** (`AERO_API_KEY`), set via
  `npx ampx sandbox secret set AERO_API_KEY`. It lives only in the `aeroapi-lookup`
  Lambda's environment — **it never ships in the iOS app**. The app calls the
  `lookupFlight` AppSync query instead.
- `amplify_outputs.json`, `.xcconfig`, `.env*`, `node_modules/`, `.amplify/`, and Xcode
  build output are gitignored.

## Hardening (before real use) — tracked in README

- [x] AeroAPI calls proxied through the `aeroapi-lookup` Lambda; key never ships in the app.
- [x] Cache AeroAPI by flightNumber+date (DynamoDB cache table + TTL).
- [x] Scheduled `flight-refresh` Lambda + SNS push for status changes (off until
      `ENABLE_PUSH=true` + APNs key; see README "Push notifications").
- [x] Cross-account `Flight` read access enforced at the row level via `viewers` +
      `ownersDefinedIn` (was previously owner-only, which actually blocked sharing).
