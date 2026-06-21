import { util } from '@aws-appsync/utils';

/**
 * Custom resolver for the `publishFlightUpdate` mutation.
 *
 * Writes the Flight row directly with a PARTIAL update: only the arguments that
 * were actually provided are written, so a caller sending just `status` doesn't
 * null out gates/times. This replaces the generated `updateFlight` so that the
 * `onConnectionFlightChange` subscription (bound to this mutation) fires for
 * viewers. The returned item is the full updated Flight, which is what the
 * subscription delivers.
 */
export function request(ctx) {
  const { id, ...rest } = ctx.arguments;

  // Keep only fields the caller actually sent (ignore null/undefined).
  const updates = {};
  for (const [k, v] of Object.entries(rest)) {
    if (v !== undefined && v !== null) updates[k] = v;
  }

  const expNames = {};
  const expValues = {};
  const sets = [];
  for (const [k, v] of Object.entries(updates)) {
    expNames[`#${k}`] = k;
    expValues[`:${k}`] = v;
    sets.push(`#${k} = :${k}`);
  }

  // Nothing to update — just read the row back (handled in response).
  if (sets.length === 0) {
    return {
      operation: 'GetItem',
      key: util.dynamodb.toMapValues({ id }),
    };
  }

  return {
    operation: 'UpdateItem',
    key: util.dynamodb.toMapValues({ id }),
    update: {
      expression: `SET ${sets.join(', ')}`,
      expressionNames: expNames,
      expressionValues: util.dynamodb.toMapValues(expValues),
    },
    // Only update an existing row.
    condition: { expression: 'attribute_exists(id)' },
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  return ctx.result;
}
