import { defineFunction } from '@aws-amplify/backend';

/**
 * Pre-token-generation trigger: injects the user's `email` into the **access
 * token** claims.
 *
 * Why: AppSync (via Amplify's API plugin) authorizes with the Cognito ACCESS
 * token, which by default has no `email` claim. Our Flight owner/viewers rules
 * match on `identityClaim('email')`, so without this the access token fails the
 * check → "Not Authorized to access listFlights on type Query".
 */
export const preTokenGeneration = defineFunction({
  name: 'pre-token-generation',
  entry: './handler.ts',
  // Live in the auth stack (it's an auth trigger) to avoid a circular dependency
  // between the auth, data, and function nested stacks.
  resourceGroupName: 'auth',
  timeoutSeconds: 5,
});
