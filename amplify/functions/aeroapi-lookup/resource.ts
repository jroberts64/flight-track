import { defineFunction, secret } from '@aws-amplify/backend';

/**
 * Server-side proxy for FlightAware AeroAPI flight lookups.
 *
 * Why this exists:
 *  1. SECURITY — the AeroAPI key never ships in the iOS binary. It's stored as
 *     an Amplify secret (`AERO_API_KEY`) and injected into the Lambda env only.
 *  2. BUDGET — the AeroAPI Personal tier gives ~$5/month (~100 status queries).
 *     This function caches results in DynamoDB keyed by flightNumber+date so
 *     repeated lookups (e.g. several family members watching one flight, or a
 *     client polling) share a single upstream call within the cache window.
 *
 * Set the secret once per environment:
 *   npx ampx sandbox secret set AERO_API_KEY
 *   (for a deployed branch: npx ampx pipeline-deploy ... then set in the console)
 */
export const aeroapiLookup = defineFunction({
  name: 'aeroapi-lookup',
  entry: './handler.ts',
  timeoutSeconds: 20,
  memoryMB: 256,
  environment: {
    AERO_API_KEY: secret('AERO_API_KEY'),
    // How long a cached lookup is considered fresh (seconds). 5 min balances
    // freshness against the per-query cost.
    CACHE_TTL_SECONDS: '300',
  },
});
