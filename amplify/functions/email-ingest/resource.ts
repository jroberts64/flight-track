import { defineFunction } from '@aws-amplify/backend';

/**
 * Inbound email → code push.
 *
 * Triggered by S3 ObjectCreated when SES inbound (on the app.jack-roberts.com
 * subdomain) writes a forwarded email to the inbound bucket. The handler parses
 * the email, identifies the forwarder by `From:` (must be a known app user),
 * infers the service from the forwarder's ServiceLinks, extracts the code, and
 * pushes it to the linked CodeGroup (owner + members) via the shared push path.
 *
 * NOT an AppSync resolver and NOT referenced by allow.resource(), so it does NOT
 * need resourceGroupName:'data' — it reads/writes the model tables via direct
 * DynamoDB IAM grants declared in backend.ts. All table names, the DeviceToken
 * and ServiceLink GSI names, the inbound bucket, the CodeEvents table, and
 * (when push is enabled) PLATFORM_APP_ARN are injected as env in backend.ts.
 */
export const emailIngest = defineFunction({
  name: 'email-ingest',
  entry: './handler.ts',
  timeoutSeconds: 60,
  memoryMB: 512,
  // Pin to the data stack. This function takes direct grants on the model
  // tables AND owns an S3 bucket that triggers it (addEventNotification) plus a
  // CodeEvents table. Splitting bucket + lambda across nested stacks makes the
  // S3 notification's Lambda::Permission cross a stack boundary while the
  // lambda's read-grant/env point back at the bucket — a circular dependency
  // (aws-cdk#5760). Co-locating lambda + bucket + tables in the data stack
  // removes every cross-stack edge. (Same footgun as flight-refresh.)
  resourceGroupName: 'data',
});
