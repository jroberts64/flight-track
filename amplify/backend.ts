import { defineBackend } from '@aws-amplify/backend';
import { auth } from './auth/resource';
import { data } from './data/resource';

/**
 * FlightTrack backend.
 *
 * Next steps (see README "Hardening"):
 *  - Add `amplify/functions/aeroapi/` to proxy FlightAware calls so the key
 *    never ships in the iOS binary, then expose it as a custom query in data.
 *  - Add a scheduled function to refresh upcoming flights + send push.
 */
defineBackend({
  auth,
  data,
});
