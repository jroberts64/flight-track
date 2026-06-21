import { extensions } from '@aws-appsync/utils';

/**
 * Custom subscription resolver for `onConnectionFlightChange`, bound to the
 * `publishFlightUpdate` mutation.
 *
 * Installs a server-side subscription filter so AppSync only delivers an event
 * to this subscriber when the subscriber's email (`viewerEmail`) is in the
 * mutated flight's `viewers` list. Lets a connection receive live updates for a
 * flight they can read but do not own, without leaking flights they aren't a
 * viewer of.
 */
export function request(ctx) {
  const { viewerEmail } = ctx.arguments;

  // IMPORTANT: this filters against the MUTATION RESPONSE fields, so every caller
  // of publishFlightUpdate must select `viewers` in its response selection set,
  // or the filter has nothing to match and the subscription silently won't fire.
  const filter = {
    filterGroup: [
      { filters: [{ fieldName: 'viewers', operator: 'contains', value: viewerEmail }] },
    ],
  };

  extensions.setSubscriptionFilter(filter);
  return { payload: null };
}

export function response(ctx) {
  return ctx.result;
}
