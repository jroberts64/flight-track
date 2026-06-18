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

### 3. iOS app

```bash
open FlightTrack.xcodeproj      # (generate via Xcode: File > New > Project, or see below)
```

The Swift sources live in `FlightTrack/`. Create an Xcode project named `FlightTrack`,
add the Amplify Swift package (https://github.com/aws-amplify/amplify-swift), add the
`FlightTrack/` sources, drop in `amplify_outputs.json`, and run.

## Data model

- **UserProfile** — one per account (display name, optional home airport).
- **Flight** — a flight owned by one user (flight number, date, route, live status snapshot).
- **FamilyLink** — connects two accounts so they can see each other's flights.

Authorization: a user owns their own flights; family members linked via an accepted
`FamilyLink` get read access. See `amplify/data/resource.ts`.

## Hardening (before real use)

- [x] Move AeroAPI calls into a Lambda (`amplify/functions/aeroapi-lookup/`) so the key
      never ships in the app. ✅ Done — app calls the `lookupFlight` AppSync query.
- [x] Rate-limit / cache AeroAPI usage (cache by flightNumber+date). ✅ Done — DynamoDB
      cache table with TTL, in `backend.ts` + the Lambda handler.
- [ ] Tighten cross-family `Flight` read access with a custom resolver (currently enforced
      in the app sync layer).
- [ ] Add a scheduled function to refresh live status for upcoming flights and push updates.
- [ ] Add push notifications for status changes (delay, gate change, departure).
