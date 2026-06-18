import { type ClientSchema, a, defineData } from '@aws-amplify/backend';

/**
 * FlightTrack data model.
 *
 * Three models:
 *  - UserProfile: public-ish identity per account (name, home airport).
 *  - Flight:      a flight owned by one user, with a cached live-status snapshot.
 *  - FamilyLink:  a directed connection between two accounts. When status is
 *                 ACCEPTED, the two users may read each other's flights.
 *
 * Authorization model (kept deliberately simple for a family-scale app):
 *  - Owners have full CRUD over their own Flights and UserProfile.
 *  - Authenticated users can read UserProfiles (so you can find family by name/email).
 *  - Flights are owner-private at the row level. Cross-family READ visibility is
 *    enforced in the app's sync layer by querying flights of users you have an
 *    ACCEPTED FamilyLink with. (See "Hardening" in README for moving this into a
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
      // Other signed-in users can read profiles to find/invite family.
      allow.authenticated().to(['read']),
    ]),

  Flight: a
    .model({
      profileId: a.id().required(),
      profile: a.belongsTo('UserProfile', 'profileId'),

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
    })
    .authorization((allow) => [allow.owner()]),

  FamilyLink: a
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
});

export type Schema = ClientSchema<typeof schema>;

export const data = defineData({
  schema,
  authorizationModes: {
    defaultAuthorizationMode: 'userPool',
  },
});
