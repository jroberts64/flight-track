import { util } from '@aws-appsync/utils';

/**
 * Custom resolver for the `publishFlightCreate` mutation.
 *
 * Writes a NEW Flight row (PutItem) and returns it. Going through this mutation
 * (rather than the generated `createFlight`) is what fires the viewer-aware
 * `onConnectionFlightCreate` subscription bound to it, so connections see the
 * new flight live. The resolver generates the `id` and the AppSync system
 * fields (`__typename`, `createdAt`, `updatedAt`) — the model's required fields
 * must be supplied by the caller (enforced at the GraphQL arg layer).
 */
export function request(ctx) {
  const id = util.autoId();
  const now = util.time.nowISO8601();

  // Keep only fields the caller actually sent (ignore null/undefined), so we
  // don't write null attributes for optional fields the caller omitted.
  const attrs = { __typename: 'Flight', createdAt: now, updatedAt: now };
  for (const [k, v] of Object.entries(ctx.arguments)) {
    if (v !== undefined && v !== null) attrs[k] = v;
  }

  return {
    operation: 'PutItem',
    key: util.dynamodb.toMapValues({ id }),
    attributeValues: util.dynamodb.toMapValues(attrs),
    // Refuse to clobber an existing row (defensive; id is freshly generated).
    condition: { expression: 'attribute_not_exists(id)' },
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  return ctx.result;
}
