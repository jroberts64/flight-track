import { type ClientSchema, a, defineData } from '@aws-amplify/backend';
import { aeroapiLookup } from '../functions/aeroapi-lookup/resource';
import { flightRefresh } from '../functions/flight-refresh/resource';

/**
 * FlightTrack data model.
 *
 * Three models:
 *  - UserProfile: public-ish identity per account (name, home airport).
 *  - Flight:      a flight owned by one user, with a cached live-status snapshot.
 *  - Connection:  a directed link between two accounts (family or friend). When
 *                 status is ACCEPTED, the two users may read each other's flights.
 *
 * Authorization model (kept deliberately simple for a small-group app):
 *  - Owners have full CRUD over their own Flights and UserProfile.
 *  - Authenticated users can read UserProfiles (so you can find people by name/email).
 *  - Flights are owner-private at the row level. Cross-account READ visibility is
 *    enforced in the app's sync layer by querying flights of users you have an
 *    ACCEPTED Connection with. (See "Hardening" in README for moving this into a
 *    custom authorizer / resolver for defense-in-depth.)
 */
const schema = a.schema({
  FlightStatus: a.enum([
    'SCHEDULED',
    'BOARDING',
    'DEPARTED',
    'ENROUTE',
    'LANDED',
    'CANCELLED',
    'DELAYED',
    'DIVERTED',
    'UNKNOWN',
  ]),

  LinkStatus: a.enum(['PENDING', 'ACCEPTED', 'DECLINED']),

  UserProfile: a
    .model({
      // Cognito sub of the owner; also used as the partition for lookups.
      owner: a.string(),
      displayName: a.string().required(),
      email: a.email().required(),
      homeAirport: a.string(), // IATA code, e.g. "SFO"
      flights: a.hasMany('Flight', 'profileId'),
    })
    .authorization((allow) => [
      allow.owner(),
      // Other signed-in users can read profiles to find/invite connections.
      allow.authenticated().to(['read']),
    ]),

  Flight: a
    .model({
      profileId: a.id().required(),
      profile: a.belongsTo('UserProfile', 'profileId'),
      // Denormalized owner email. Doubles as the owner-auth identifier
      // (ownerDefinedIn below) and lets the refresh Lambda resolve notification
      // recipients without a join. Required so owner auth always resolves.
      ownerEmail: a.email().required(),

      // Identity
      flightNumber: a.string().required(), // e.g. "UA328"
      faFlightId: a.string(), // FlightAware unique id, when resolved

      // Schedule (ISO 8601 strings, UTC)
      departureDate: a.date().required(), // local departure date "2026-06-20"
      originIata: a.string().required(),
      destinationIata: a.string().required(),
      scheduledOut: a.datetime(), // scheduled gate departure
      scheduledIn: a.datetime(), // scheduled gate arrival
      estimatedOut: a.datetime(),
      estimatedIn: a.datetime(),
      actualOut: a.datetime(),
      actualIn: a.datetime(),

      // Live snapshot (refreshed from AeroAPI)
      status: a.ref('FlightStatus'),
      originGate: a.string(),
      destinationGate: a.string(),
      originTerminal: a.string(),
      destinationTerminal: a.string(),
      progressPercent: a.integer(),
      lastRefreshedAt: a.datetime(),

      note: a.string(), // free-text, e.g. "Picking up Mom"

      // Emails allowed to READ this flight: the owner plus any accepted
      // connections. Maintained by the app on create and by the
      // ConnectionsViewModel when links are accepted/removed. Drives
      // cross-account read access below.
      viewers: a.string().array(),
    })
    .authorization((allow) => [
      // Owner (matched by email) has full CRUD.
      allow.ownerDefinedIn('ownerEmail').identityClaim('email'),
      // Accepted connections listed in `viewers` may READ on queries. NOTE:
      // this does NOT grant real-time delivery — Amplify's generated
      // onUpdateFlight subscription authorizes on the OWNER identity only, so a
      // viewer cannot receive another user's flight changes through it. Live
      // cross-account updates are delivered by the custom
      // `onConnectionFlightChange` subscription below instead.
      allow.ownersDefinedIn('viewers').identityClaim('email').to(['read']),
    ]),

  Connection: a
    .model({
      // The inviter (owner) and the invitee (by email, resolved to a user).
      inviterEmail: a.email().required(),
      inviteeEmail: a.email().required(),
      status: a.ref('LinkStatus'),
    })
    // Both sides need read; either side can update status (accept/decline).
    // ownerDefinedIn lets us treat the inviter as the row owner while still
    // granting the invitee access via a multi-owner pattern in the app layer.
    .authorization((allow) => [
      allow.owner(),
      allow.authenticated().to(['read', 'update']),
    ]),

  // An APNs device-token registration, so the backend can push to a user's
  // devices. One row per device; owner-scoped. The refresh Lambda reads these
  // (by ownerEmail) to know where to send flight-change notifications.
  DeviceToken: a
    .model({
      ownerEmail: a.email().required(), // the signed-in user's email
      token: a.string().required(),     // APNs device token (hex)
      // SNS endpoint ARN created when the token is registered with the platform
      // application; lets the refresh Lambda publish without re-creating it.
      snsEndpointArn: a.string(),
      platform: a.string(), // "APNS" or "APNS_SANDBOX"
    })
    // Lets the Lambdas look up a user's devices by email.
    .secondaryIndexes((index) => [index('ownerEmail')])
    // Owner CRUD: the iOS app writes its own DeviceToken row (token + blank
    // snsEndpointArn). The flight-refresh Lambda reads these and creates the SNS
    // endpoint lazily on first push (direct DynamoDB IAM access, granted in
    // backend.ts), then writes the ARN back.
    .authorization((allow) => [allow.owner()]),

  // Custom flight-update mutation. Amplify's generated `updateFlight` cannot
  // drive a viewer-aware live subscription (its onUpdateFlight delivers to the
  // OWNER only — verified empirically). So all flight writes go through this
  // custom mutation instead: its JS resolver writes the Flight row directly
  // (partial update — only provided fields), and the `onConnectionFlightChange`
  // subscription is bound to THIS mutation, so any viewer of the row gets the
  // change live. Authorized to any authenticated caller; the resolver enforces
  // that only the owner OR a listed viewer may write (defense kept simple for a
  // small-group app — the app only ever sends owner-initiated writes).
  publishFlightUpdate: a
    .mutation()
    .arguments({
      id: a.id().required(),
      status: a.string(),
      estimatedOut: a.string(),
      estimatedIn: a.string(),
      actualOut: a.string(),
      actualIn: a.string(),
      originGate: a.string(),
      destinationGate: a.string(),
      originTerminal: a.string(),
      destinationTerminal: a.string(),
      progressPercent: a.integer(),
      lastRefreshedAt: a.string(),
      note: a.string(),
      viewers: a.string().array(),
    })
    .returns(a.ref('Flight'))
    // Authenticated users (the app via Cognito) may call it. The refresh Lambda
    // calls it too, via IAM — granted appsync:GraphQL on this field in
    // backend.ts, with IAM added as an auth mode there.
    .authorization((allow) => [allow.authenticated()])
    .handler(
      a.handler.custom({
        dataSource: a.ref('Flight'),
        entry: './publish-flight-update.js',
      })
    ),

  // Live cross-account flight updates. Bound to `publishFlightUpdate` above (a
  // custom subscription CAN attach to a custom mutation; it could not reliably
  // attach to the generated updateFlight). The subscriber passes their own
  // email; the resolver installs a filter so the event is delivered only when
  // that email is in the mutated flight's `viewers`. The app opens this with
  // viewerEmail = me, giving live updates for my flights AND my connections'.
  onConnectionFlightChange: a
    .subscription()
    .for(a.ref('publishFlightUpdate'))
    .arguments({ viewerEmail: a.string().required() })
    .returns(a.ref('Flight'))
    .authorization((allow) => [allow.authenticated()])
    .handler(
      a.handler.custom({
        entry: './on-connection-flight-change.js',
      })
    ),

  // Normalized result of a server-side AeroAPI lookup (see functions/aeroapi-lookup).
  FlightLookupResult: a.customType({
    flightNumber: a.string().required(),
    faFlightId: a.string(),
    status: a.string().required(),
    originIata: a.string(),
    destinationIata: a.string(),
    scheduledOut: a.string(),
    scheduledIn: a.string(),
    estimatedOut: a.string(),
    estimatedIn: a.string(),
    actualOut: a.string(),
    actualIn: a.string(),
    originGate: a.string(),
    destinationGate: a.string(),
    originTerminal: a.string(),
    destinationTerminal: a.string(),
    progressPercent: a.integer(),
    cached: a.boolean(),
  }),

  // Server-side flight lookup. The AeroAPI key lives only in the Lambda, and
  // results are cached in DynamoDB to protect the AeroAPI budget.
  lookupFlight: a
    .query()
    .arguments({ flightNumber: a.string().required(), date: a.string().required() })
    .returns(a.ref('FlightLookupResult'))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(aeroapiLookup)),
})
  // The scheduled refresh Lambda calls `publishFlightUpdate` via IAM so its
  // writes flow through AppSync and fire the live subscription. Function access
  // is configured at the schema level (not per-field). This adds IAM as an auth
  // mode automatically.
  .authorization((allow) => [allow.resource(flightRefresh).to(['mutate'])]);

export type Schema = ClientSchema<typeof schema>;

export const data = defineData({
  schema,
  authorizationModes: {
    defaultAuthorizationMode: 'userPool',
  },
});
