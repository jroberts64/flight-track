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
| `amplify/data/resource.ts` | Data model + authorization: `UserProfile`, `Flight`, `FamilyLink`. Single source of truth for the backend schema. |
| `amplify/backend.ts` | Backend entrypoint: wires auth + data + the AeroAPI Lambda, and provisions the DynamoDB cache table (TTL) granted to the Lambda. |
| `amplify/functions/aeroapi-lookup/` | Lambda that proxies FlightAware AeroAPI server-side (key as an Amplify secret) with a DynamoDB cache. Exposed as the `lookupFlight` AppSync query. |
| `FlightTrack/App/` | App entrypoint (`FlightTrackApp`), `RootView` (auth gate + tabs), `SessionStore` (per-session identity + profile id). |
| `FlightTrack/Models/` | Domain models (`Flight`/`FlightStatus`, `UserProfile`/`FamilyLink`) + AeroAPI decodables. Decoupled from Amplify codegen on purpose. |
| `FlightTrack/Services/` | `AmplifyBootstrap`, `AuthService` (Cognito), `FlightRepository` (GraphQL CRUD + real-time subscription), `AeroAPIClient` (calls the `lookupFlight` backend query — NOT FlightAware directly), `JSONMapping` (JSONValue ↔ domain). |
| `FlightTrack/ViewModels/` | `FlightsViewModel`, `FamilyViewModel`. |
| `FlightTrack/Views/` | SwiftUI screens: auth, my-flights + add-flight, family, flight row. |
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
  has full CRUD; any authenticated user can *read* (so you can find family by email).
- **Flight** — owned by one user; carries a cached AeroAPI live-status snapshot
  (status, gates, terminals, scheduled/estimated/actual times, progress). Owner-only.
- **FamilyLink** — directed invite (inviterEmail → inviteeEmail) with status
  PENDING/ACCEPTED/DECLINED. When ACCEPTED, the app loads the counterparty's flights.

Cross-family read visibility is currently enforced in the **app sync layer**, not the
row-level auth rules — see "Hardening" below.

## Conventions

- Keep the four Amplify runtime concerns in their `resource.ts` files; don't scatter
  schema definitions.
- Swift domain models are deliberately separate from Amplify's generated types — views
  and view models depend only on `FlightTrack/Models`, and `JSONMapping.swift` bridges
  to GraphQL. Keep that boundary.
- GraphQL documents in `FlightRepository`/`FamilyViewModel` are hand-written so the app
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
- [ ] Tighten cross-family `Flight` read access with a custom resolver/authorizer rather
      than relying on the app sync layer.
- [ ] Scheduled function to refresh upcoming flights + push status-change notifications.
