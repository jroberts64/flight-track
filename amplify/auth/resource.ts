import { defineAuth } from '@aws-amplify/backend';

/**
 * Cognito auth for FlightTrack.
 * Users sign in with email. A verified email is required so that family
 * invitations can be addressed by email address.
 */
export const auth = defineAuth({
  loginWith: {
    email: true,
  },
  userAttributes: {
    // Shown to family members instead of a raw user id.
    preferredUsername: {
      mutable: true,
      required: false,
    },
  },
});
