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
| `amplify/data/resource.ts` | Data model + authorization: `UserProfile`, `Flight`, `Connection`, `CodeGroup`, `ServiceLink`. Single source of truth for the backend schema. |
| `amplify/backend.ts` | Backend entrypoint: wires auth + data + the Lambdas, provisions the AeroAPI cache + `CodeEvents` (TTL) tables, the inbound-email S3 bucket + S3→Lambda trigger, and the SNS push stack (on unless `ENABLE_PUSH=false`). |
| `amplify/functions/aeroapi-lookup/` | Lambda that proxies FlightAware AeroAPI server-side (key as an Amplify secret) with a DynamoDB cache. Exposed as the `lookupFlight` AppSync query. Pinned to the **data** stack (`resourceGroupName: 'data'`) to avoid a circular dependency. |
| `amplify/functions/flight-refresh/` | Scheduled (30m) Lambda. Refreshes near-window flights via AeroAPI, diffs, updates, and pushes change alerts via SNS. Uses the shared push helper. |
| `amplify/functions/email-ingest/` | S3-triggered Lambda. Parses a forwarded code email, validates the sender is an app user, matches a `ServiceLink`, extracts the code, stores an ephemeral `CodeEvents` row (TTL), and pushes to the linked `CodeGroup`. Pinned to **data** (`resourceGroupName: 'data'`) so the bucket + lambda + tables co-locate (else S3-notification↔lambda is a circular dep). |
| `amplify/functions/shared/push.ts` | Shared APNs helpers (`ensureEndpoint`, `endpointsForEmails`, `publish`) used by both `flight-refresh` and `email-ingest`. `publish` takes a generic payload (`{ flightId }` or `{ kind:'code', … }`). |
| `FlightTrack/App/` | App entrypoint (`FlightTrackApp`), `AppDelegate` (APNs token + routes `kind:"code"` pushes to `.codePushReceived`, else `.flightPushReceived`), `RootView` (auth gate + 4 tabs), `SessionStore`. |
| `FlightTrack/Models/` | Domain models (`Flight`/`FlightStatus`, `UserProfile`/`Connection`, `CodeGroup`/`ServiceLink`/`ServicePreset`) + AeroAPI decodables. Decoupled from Amplify codegen on purpose. |
| `FlightTrack/Services/` | `AmplifyBootstrap`, `AuthService` (Cognito), `FlightRepository` (flight/connection CRUD + subscriptions), `CodeGroupRepository` (code-group + service-link CRUD), `AeroAPIClient`, `PushService`, `JSONMapping` (JSONValue ↔ domain). |
| `FlightTrack/ViewModels/` | `FlightsViewModel`, `ConnectionsViewModel`, `CodeGroupsViewModel`. |
| `FlightTrack/Views/` | SwiftUI screens: auth, my-flights + add-flight, connections, flight row, codes (groups + service links). |
| `FlightTrack/Config/` | `SETUP.md` (Xcode project creation + secret setup). |
| `deploy/` | `github-oidc.yaml` (CI deploy role), `bootstrap-oidc.sh` (one-time role create), `setup-git-account.sh` + `git-credential-jroberts64.sh` (pin repo push-auth to the jroberts64 account). |
| `.github/workflows/deploy-backend.yml` | CI: `ampx pipeline-deploy` on push to main via OIDC. |

## AWS access

Account **`019135476568`**, region **`us-east-1`**.

- **Local:** `aws sso login --sso-session personal-sso` then `export AWS_PROFILE=personal-sso`.
- **CI:** GitHub Actions OIDC — no stored secrets. The OIDC provider is account-wide and
  already exists (created by the `bin-builder` repo); `github-oidc.yaml` reuses it
  (`CreateOIDCProvider=false`) and adds a repo+branch-scoped role. CI deploys a SEPARATE
  prod Amplify app (`flight-track` / `d2ogdfod3pca1q`), not your `ampx sandbox` stack, and
  runs with **`ENABLE_PUSH=false`** (no APNs `.p8` in CI). Bootstrap details + gotchas
  (`/service-role/` policy path, `GITHUB_REPO=flight-track` override, the app's `main`
  branch must pre-exist) are in the README "CI deploys" section.

## GitHub account (push auth)

The repo is **`jroberts64/flight-track`**. `gh`'s single active account can flip to another
account on this machine → `git push` 403s ("denied to jroberts-juicerpricing"). This repo is
pinned LOCALLY to `jroberts64` via `deploy/setup-git-account.sh` (sets repo-local user +
routes credentials through `deploy/git-credential-jroberts64.sh`, which serves the jroberts64
token regardless of gh's active account). If a push still 403s, run that script (or
`gh auth switch --user jroberts64`). Never change global git/gh config to fix it.

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
- **CodeGroup** — a named group of connections that receive shared service codes
  (ownerEmail, name, `memberEmails`). Owner CRUD; members get READ via
  `ownersDefinedIn('memberEmails')`. Delivery is push, so (unlike Flight) there's no
  live cross-account subscription — the app uses the generated CRUD mutations.
- **ServiceLink** — maps a service to a `CodeGroup` (ownerEmail, groupId, serviceName,
  `matchRules` JSON, enabled). Owner-private. GSI on `ownerEmail`
  (`serviceLinksByOwnerEmail`) so `email-ingest` finds a sender's links.
- **CodeEvents** — custom (non-model) DynamoDB table with TTL, holding the ephemeral
  "latest code" per `groupId#serviceName` (~15 min). Kept out of the AppSync graph so
  the secret isn't queryable; written by `email-ingest`.

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
creates a circular dependency between the data and function nested stacks. The same
applies to `email-ingest`: its S3 bucket triggers it AND it reads model tables, so the
bucket + lambda + tables must be **co-located in the data stack** (lambda pinned to
`resourceGroupName: 'data'`, bucket created in `ingestLambda.stack`) — otherwise the
S3-notification ↔ lambda references cycle across nested stacks (aws-cdk#5760).

**Push is on by default.** `backend.ts` provisions the SNS platform app unless
`ENABLE_PUSH=false`; the deploy shell must export the APNs vars (local convention:
`source ~/.apple-developer/flighttrack.env`). See memory `cli-device-build` /
`flight-track-project` and the README "Push notifications".

**Inbound email (code sharing).** SES receives `decode@app.jack-roberts.com` → S3 →
`email-ingest`. The SES identity + DKIM + subdomain MX live in Route 53 (apex MX stays
on WorkMail). CRITICAL: WorkMail owns the single ACTIVE SES receipt rule set
(`INBOUND_MAIL`); the `decode@` → S3 rule is added INTO that set out-of-band (CLI), not
via CloudFormation — activating a competing set would break WorkMail mail. So `ampx
sandbox` does not manage that rule; re-add it if WorkMail rewrites its set. Full setup
steps are in the README "Code sharing".

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
