import {
  SNSClient,
  PublishCommand,
  CreatePlatformEndpointCommand,
} from '@aws-sdk/client-sns';
import { DynamoDBDocumentClient, QueryCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';

/**
 * Shared APNs push helpers, used by BOTH the scheduled flight-refresh Lambda and
 * the email-ingest Lambda so there's one endpoint-minting path and one APNs
 * payload shape. Extracted from flight-refresh/handler.ts.
 *
 * Push is deploy-gated: when `platformAppArn` is undefined (ENABLE_PUSH not set
 * at deploy time) ensureEndpoint returns null and nothing is sent.
 */

export interface PushConfig {
  /** DeviceToken table name. */
  deviceTable: string;
  /** GSI name on DeviceToken.ownerEmail (deviceTokensByOwnerEmail). */
  gsiName: string;
  /** SNS platform application ARN; undefined when push is disabled. */
  platformAppArn?: string;
}

/**
 * Returns the device's SNS endpoint ARN, creating it lazily on first use. The
 * iOS app writes DeviceToken rows with no endpoint; we mint one from the raw
 * APNs token, persist it, and reuse it on subsequent runs.
 */
export async function ensureEndpoint(
  ddb: DynamoDBDocumentClient,
  sns: SNSClient,
  device: Record<string, any>,
  cfg: PushConfig
): Promise<string | null> {
  if (device.snsEndpointArn) return device.snsEndpointArn as string;
  if (!cfg.platformAppArn || !device.token) return null;
  try {
    const created = await sns.send(
      new CreatePlatformEndpointCommand({
        PlatformApplicationArn: cfg.platformAppArn,
        Token: device.token,
        CustomUserData: device.ownerEmail,
      })
    );
    const arn = created.EndpointArn!;
    await ddb.send(
      new UpdateCommand({
        TableName: cfg.deviceTable,
        Key: { id: device.id },
        UpdateExpression: 'SET snsEndpointArn = :a, updatedAt = :u',
        ExpressionAttributeValues: { ':a': arn, ':u': new Date().toISOString() },
      })
    );
    return arn;
  } catch (e) {
    console.error(`failed to create endpoint for ${device.ownerEmail}:`, e);
    return null;
  }
}

/**
 * Resolves SNS endpoint ARNs for a set of recipient emails: queries the
 * DeviceToken GSI per email and mints/loads each device's endpoint.
 */
export async function endpointsForEmails(
  ddb: DynamoDBDocumentClient,
  sns: SNSClient,
  emails: Iterable<string>,
  cfg: PushConfig
): Promise<string[]> {
  const arns: string[] = [];
  for (const email of emails) {
    const res = await ddb
      .send(
        new QueryCommand({
          TableName: cfg.deviceTable,
          IndexName: cfg.gsiName,
          KeyConditionExpression: 'ownerEmail = :e',
          ExpressionAttributeValues: { ':e': email },
        })
      )
      .catch((err) => {
        console.error(`device lookup failed for ${email}:`, err);
        return null;
      });
    for (const item of res?.Items ?? []) {
      const arn = await ensureEndpoint(ddb, sns, item, cfg);
      if (arn) arns.push(arn);
    }
  }
  return arns;
}

/**
 * Publishes an APNs alert to one endpoint. `payload` is merged into the APNs
 * JSON alongside `aps`, letting callers attach app-routing data — e.g.
 * `{ flightId }` for flight changes or `{ kind: 'code', service, group, code }`
 * for shared service codes.
 */
export async function publish(
  sns: SNSClient,
  endpointArn: string,
  title: string,
  body: string,
  payload: Record<string, unknown> = {}
): Promise<void> {
  const apns = JSON.stringify({
    // `content-available: 1` lets iOS wake the app in the background before the
    // user opens it; the alert still shows.
    aps: { alert: { title, body }, sound: 'default', 'content-available': 1 },
    ...payload,
  });
  await sns.send(
    new PublishCommand({
      TargetArn: endpointArn,
      MessageStructure: 'json',
      Message: JSON.stringify({ default: body, APNS: apns, APNS_SANDBOX: apns }),
    })
  );
}
