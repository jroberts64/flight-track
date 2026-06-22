import { util } from '@aws-appsync/utils';

/**
 * Custom resolver for the `publishFlightDelete` mutation.
 *
 * Deletes the Flight row and returns the deleted item. Going through this
 * mutation (rather than a generated deleteFlight or a raw DynamoDB DeleteItem)
 * is what fires the `onConnectionFlightDelete` subscription bound to it, so
 * every viewer of the row is notified live. DeleteItem returns the OLD item as
 * `ctx.result`, which carries `viewers` — required by the subscription's
 * viewer-email filter.
 */
export function request(ctx) {
  return {
    operation: 'DeleteItem',
    key: util.dynamodb.toMapValues({ id: ctx.arguments.id }),
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  return ctx.result;
}
