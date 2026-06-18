import { defineFunction, secret } from '@aws-amplify/backend';

/**
 * Scheduled flight-status refresher + push notifier.
 *
 * Runs every 30 minutes. For each flight departing or arriving within the next
 * ~3 hours (the "near window"), it re-queries AeroAPI, diffs against the stored
 * snapshot, and — on a meaningful change (delay, gate/terminal change, departed,
 * landed, cancelled, diverted) — updates the flight and pushes a notification to
 * the flight's owner and any family members with an ACCEPTED FamilyLink.
 *
 * Budget: only near-window flights are refreshed, and AeroAPI responses are
 * cached (the lookup path shares the same DynamoDB cache), so a quiet period
 * costs nothing and a busy one stays within the Personal tier.
 */
export const flightRefresh = defineFunction({
  name: 'flight-refresh',
  entry: './handler.ts',
  timeoutSeconds: 120,
  memoryMB: 512,
  // Every 30 minutes. (Amplify schedule cron — minute granularity.)
  schedule: 'every 30m',
  environment: {
    AERO_API_KEY: secret('AERO_API_KEY'),
    NEAR_WINDOW_HOURS: '3',
    CACHE_TTL_SECONDS: '300',
  },
});
