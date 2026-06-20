import type { PreTokenGenerationV2TriggerHandler } from 'aws-lambda';

/**
 * Adds the user's `email` to the access token so AppSync owner/viewers rules
 * (which match on identityClaim('email')) resolve.
 *
 * Uses the V2 trigger contract (`claimsAndScopeOverrideDetails`) because only
 * V2_0+ can override ACCESS-token claims; the classic V1 contract can only
 * touch the ID token.
 */
export const handler: PreTokenGenerationV2TriggerHandler = async (event) => {
  const email = event.request.userAttributes?.email;
  if (email) {
    event.response = {
      claimsAndScopeOverrideDetails: {
        accessTokenGeneration: {
          claimsToAddOrOverride: { email },
        },
      },
    };
  }
  return event;
};
