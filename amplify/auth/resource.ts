import { defineAuth } from '@aws-amplify/backend';
import { preTokenGeneration } from './pre-token-generation/resource';

/**
 * Cognito auth for FlightTrack.
 * Users sign in with email. A verified email is required so that connection
 * invitations can be addressed by email address.
 *
 * Email delivery:
 *  - By default Cognito uses its built-in sender (no-reply@verificationemail.com).
 *    It works but is unbranded, rate-limited, and frequently lands in spam.
 *  - To send via Amazon SES from a domain you own (proper SPF/DKIM/DMARC, far
 *    better inbox placement), set COGNITO_SENDER_EMAIL at deploy time to a
 *    verified SES identity, e.g.:
 *
 *      export COGNITO_SENDER_EMAIL="no-reply@yourdomain.com"
 *      export COGNITO_SENDER_NAME="FlightTrack"        # optional
 *      npx ampx sandbox
 *
 *    Prereqs (see README "Email delivery"): verify the address/domain in SES,
 *    add the DKIM/SPF DNS records SES provides, and request SES production
 *    access (the SES sandbox only sends to pre-verified recipients).
 */
const senderEmail = process.env.COGNITO_SENDER_EMAIL;

export const auth = defineAuth({
  loginWith: {
    email: true,
  },
  userAttributes: {
    // Shown to connections instead of a raw user id.
    preferredUsername: {
      mutable: true,
      required: false,
    },
  },
  // Inject `email` into the access token so AppSync owner/viewers rules
  // (identityClaim('email')) resolve.
  triggers: {
    preTokenGeneration,
  },
  // Only attach a custom SES sender when configured; otherwise Cognito's
  // default sender is used and the backend still deploys cleanly.
  ...(senderEmail
    ? {
        senders: {
          email: {
            fromEmail: senderEmail,
            fromName: process.env.COGNITO_SENDER_NAME ?? 'FlightTrack',
          },
        },
      }
    : {}),
});
