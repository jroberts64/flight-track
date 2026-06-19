# FlightTrack

An iOS app to track your flights, share them with family, and see theirs — with live
flight status from FlightAware AeroAPI and real-time sync via AWS Amplify Gen 2.

## Stack

| Layer        | Choice                                                        |
|--------------|---------------------------------------------------------------|
| iOS app      | Native Swift / SwiftUI (iOS 17+)                              |
| Auth         | AWS Cognito (via Amplify Gen 2)                               |
| Data + sync  | AWS AppSync (GraphQL real-time) + DynamoDB                    |
| Push         | Amazon Pinpoint / SNS (via Amplify Notifications)            |
| Flight data  | FlightAware AeroAPI                                           |

## Repository layout

```
filght-track/
├── amplify/                 # AWS Amplify Gen 2 backend (TypeScript)
│   ├── auth/resource.ts     # Cognito auth config
│   ├── data/resource.ts     # Data model + authorization rules
│   └── backend.ts           # Backend entrypoint
├── FlightTrack/             # SwiftUI iOS app
│   ├── App/                 # App entrypoint + Amplify bootstrap
│   ├── Models/              # Swift domain models
│   ├── Services/            # AeroAPI client, sync service, auth
│   ├── ViewModels/          # Observable view models
│   └── Views/               # SwiftUI screens
├── package.json             # Amplify backend deps
└── README.md
```

## Setup

### 1. Backend (AWS Amplify Gen 2)

Prereqs: Node 18+ and AWS access. This account uses **AWS SSO**:

```bash
aws sso login --sso-session personal-sso
export AWS_PROFILE=personal-sso          # account 019135476568, region us-east-1
```

Then spin up a personal cloud sandbox:

```bash
npm install
npx ampx sandbox        # deploys to your account + writes amplify_outputs.json
```

`amplify_outputs.json` is generated at the repo root — drag it into the Xcode project
(target: FlightTrack) so the app can find your backend.

### CI deploys (GitHub Actions via OIDC — no stored secrets)

Modeled on the `bin-builder` deploy pattern. The GitHub OIDC provider already
exists account-wide (created by bin-builder), so we only add a repo-scoped role.

```bash
# one-time: create the repo-scoped Amplify deploy role
export AWS_PROFILE=personal-sso
./deploy/bootstrap-oidc.sh        # prints the DeployRoleArn
```

Then in GitHub (repo → Settings → Secrets and variables → Actions → **Variables**) set:
- `AWS_DEPLOY_ROLE_ARN` → the printed role ARN
- `AMPLIFY_APP_ID` → your Amplify app id (from the Amplify console)

`.github/workflows/deploy-backend.yml` then runs `ampx pipeline-deploy` on every
push to `main`, assuming that role via a short-lived OIDC token.

> Scope note: the CI role uses the AWS-managed `AmplifyBackendDeployFullAccess`
> policy. Amplify Gen 2 provisions Cognito/AppSync/DynamoDB/Lambda/IAM via CDK,
> so its action set isn't cleanly hand-enumerable — this is the AWS-documented
> grant for backend CI deploys. It's broader than bin-builder's tight
> S3+CloudFront role; that's inherent to deploying a stateful backend vs a static site.

### 2. FlightAware AeroAPI key (server-side only)

The AeroAPI key **never ships in the app**. It's stored as an Amplify secret and used
only by the `aeroapi-lookup` Lambda; the iOS client calls the `lookupFlight` AppSync
query, and the Lambda caches results in DynamoDB to protect the AeroAPI budget.

1. Sign up at https://www.flightaware.com/aeroapi/portal/ and create an API key.
   The **Personal** tier ($5/month credit) covers a family-scale app — see notes below.
2. Set it as a secret:
   ```bash
   npx ampx sandbox secret set AERO_API_KEY     # paste the key
   ```
   For a deployed branch, set it in the Amplify console (App settings → Secrets).

> **Budget:** AeroAPI Personal gives ~$5/month (~100 status queries at ~$0.05 each).
> The Lambda caches by flightNumber+date (5-min TTL) so repeated lookups — and multiple
> family members watching one flight — share a single upstream call. Don't poll
> aggressively; the cache is what keeps you inside the free credit.

### 3. Email delivery (verification codes)

By default Cognito sends sign-up/verification emails from its built-in sender
(`no-reply@verificationemail.com`) — functional but **frequently flagged as spam**.
For real use, send via Amazon SES from a domain you own:

1. **Verify a sender in SES** (us-east-1). Either:
   - a **single email address** (quick, no DNS — good for testing your own signups), or
   - a **domain** (`yourdomain.com`) — add the DKIM CNAME records SES gives you, plus
     an SPF TXT record. Better deliverability; required for arbitrary recipients.
2. **Request SES production access** — new SES accounts are in a *sandbox* that only
   sends to pre-verified addresses. File the "production access" request in the SES
   console (usually approved within a day). Skip only if you stay in sandbox for testing.
3. **Point Cognito at it** — set the sender at deploy time and redeploy:
   ```bash
   export COGNITO_SENDER_EMAIL="no-reply@yourdomain.com"   # the verified identity
   export COGNITO_SENDER_NAME="FlightTrack"                # optional
   npx ampx sandbox          # (or pipeline-deploy with these in CI env)
   ```
   `amplify/auth/resource.ts` reads these and attaches an SES sender only when set;
   unset = default Cognito sender, deploys unchanged.

### 4. iOS app

The Xcode project already exists at `FlightTrack.xcodeproj` (sources in `FlightTrack/`,
Amplify package added, `amplify_outputs.json` in the source dir). See
`FlightTrack/Config/SETUP.md` for build/run details. Open it and ⌘R, or build from the
CLI per that doc. Requires the iOS 26.5 simulator runtime.

## Data model

- **UserProfile** — one per account (display name, optional home airport).
- **Flight** — a flight owned by one user (flight number, date, route, live status snapshot).
- **FamilyLink** — connects two accounts so they can see each other's flights.

Authorization: a user owns their own flights; family members linked via an accepted
`FamilyLink` get read access. See `amplify/data/resource.ts`.

## Push notifications

The backend pushes flight-change alerts (delay, gate/terminal change, departed,
landed, cancelled, diverted) to the flight owner and accepted family members.

How it works:
- `flight-refresh` Lambda runs every 30 min, refreshes flights within ~3 hours of
  departure/arrival, diffs against the stored snapshot, and on a meaningful change
  updates the flight and publishes via **Amazon SNS** (APNs).
- The iOS app requests notification permission after sign-in, registers with APNs,
  and writes a `DeviceToken` row. The Lambda creates the SNS endpoint **lazily** on
  first push (no separate registration Lambda).

### Enabling push (needs an Apple Developer account)

Push is **off by default** so the rest of the app deploys without Apple setup.
To turn it on:

1. **Apple Developer account** ($99/yr). In the developer portal:
   - Create an **APNs Auth Key** (Keys → +, enable "Apple Push Notifications service").
     Download the `.p8` (you can only download it once). Note the **Key ID** and your
     **Team ID**.
   - Ensure the app's **Bundle ID** has the Push Notifications capability, and add the
     "Push Notifications" capability to the target in Xcode.
2. Deploy with push enabled (these are read at deploy time, NOT runtime secrets —
   the `.p8` lands in the CloudFormation template, so keep the deploy env private):
   ```bash
   export AWS_PROFILE=personal-sso
   export ENABLE_PUSH=true
   export APNS_SIGNING_KEY="$(cat AuthKey_XXXXXXXXXX.p8)"
   export APNS_KEY_ID=XXXXXXXXXX
   export APNS_TEAM_ID=YYYYYYYYYY
   export APNS_BUNDLE_ID=com.yourorg.flighttrack
   export APNS_SANDBOX=true     # for Xcode dev builds; omit/false for TestFlight/App Store
   npx ampx sandbox
   ```
3. Run on a **physical device** (remote push doesn't work in the simulator).

> Remote push requires the production APNs environment for App Store / TestFlight
> builds and the sandbox environment for development builds — set `APNS_SANDBOX`
> accordingly. A device registered against one won't receive from the other.

## Hardening (before real use)

- [x] Move AeroAPI calls into a Lambda (`amplify/functions/aeroapi-lookup/`) so the key
      never ships in the app. ✅ app calls the `lookupFlight` AppSync query.
- [x] Cache AeroAPI usage (flightNumber+date, DynamoDB TTL). ✅
- [x] Scheduled refresh of upcoming flights + push on status changes. ✅
      (`flight-refresh` + SNS).
- [ ] Tighten cross-family `Flight` read access with a custom resolver (currently enforced
      in the app sync layer).
