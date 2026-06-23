import type { S3Handler } from 'aws-lambda';
import { S3Client, GetObjectCommand } from '@aws-sdk/client-s3';
import { SNSClient } from '@aws-sdk/client-sns';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient,
  ScanCommand,
  QueryCommand,
  GetCommand,
  PutCommand,
} from '@aws-sdk/lib-dynamodb';
import { simpleParser } from 'mailparser';
import { endpointsForEmails, publish } from '../shared/push';

/**
 * SES-inbound → code-push handler. See resource.ts for the pipeline overview.
 *
 * Env (injected by backend.ts):
 *   USER_PROFILE_TABLE     — DynamoDB table for UserProfile (sender validation)
 *   SERVICE_LINK_TABLE     — DynamoDB table for ServiceLink
 *   SERVICE_LINK_BY_EMAIL  — GSI name on ServiceLink.ownerEmail
 *   CODE_GROUP_TABLE       — DynamoDB table for CodeGroup
 *   CODE_EVENTS_TABLE      — custom TTL table for the ephemeral "latest code"
 *   DEVICE_TOKEN_TABLE     — DynamoDB table for DeviceToken
 *   DEVICE_TOKEN_BY_EMAIL  — GSI name on DeviceToken.ownerEmail
 *   PLATFORM_APP_ARN       — SNS platform app ARN (unset until push enabled)
 *
 * SECURITY: never log the code or the raw email body — only service name and
 * recipient count. Codes are secrets; the raw email rests in S3 (short TTL) and
 * the latest code in CodeEvents (TTL ~15m).
 */

const s3 = new S3Client({});
const sns = new SNSClient({});
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const USER_PROFILE_TABLE = process.env.USER_PROFILE_TABLE!;
const SERVICE_LINK_TABLE = process.env.SERVICE_LINK_TABLE!;
const CODE_GROUP_TABLE = process.env.CODE_GROUP_TABLE!;
const CODE_EVENTS_TABLE = process.env.CODE_EVENTS_TABLE!;

const CODE_TTL_SECONDS = 15 * 60;

const pushCfg = {
  deviceTable: process.env.DEVICE_TOKEN_TABLE!,
  gsiName: process.env.DEVICE_TOKEN_BY_EMAIL!,
  platformAppArn: process.env.PLATFORM_APP_ARN,
};

interface MatchRules {
  fromContains?: string;
  subjectContains?: string;
  codeRegex?: string;
}

export const handler: S3Handler = async (event) => {
  for (const record of event.Records) {
    const bucket = record.s3.bucket.name;
    const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, ' '));
    try {
      await processOne(bucket, key);
    } catch (e) {
      console.error(`email-ingest failed for ${key}:`, e);
    }
  }
};

async function processOne(bucket: string, key: string): Promise<void> {
  const obj = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  const raw = await obj.Body!.transformToByteArray();
  const mail = await simpleParser(Buffer.from(raw));

  const fromEmail = (mail.from?.value?.[0]?.address ?? '').toLowerCase().trim();
  const subject = mail.subject ?? '';
  const body = `${mail.text ?? ''}\n${mail.html || ''}`;

  if (!fromEmail) {
    console.log('email-ingest: no From: address, dropping');
    return;
  }

  // Defense-in-depth: log the auth verdict (SES receipt-rule scan + DMARC).
  const authResults = (mail.headers.get('authentication-results') as string) ?? '';
  if (authResults) console.log(`email-ingest: auth-results present (${authResults.length} chars)`);

  // 1) Sender gate — must be a known app user.
  const sender = await findUserByEmail(fromEmail);
  if (!sender) {
    console.log(`email-ingest: sender ${fromEmail} is not an app user, dropping`);
    return;
  }

  // 2) Find the first enabled ServiceLink whose rules match this email.
  const links = await serviceLinksFor(fromEmail);
  const link = links.find((l) => l.enabled !== false && matches(l, fromEmail, subject, body));
  if (!link) {
    console.log(`email-ingest: no matching ServiceLink for ${fromEmail}, dropping`);
    return;
  }

  // 3) Extract the code.
  const code = extractCode(link.matchRules, body, subject);
  if (!code) {
    console.log(`email-ingest: no code found for service ${link.serviceName}, dropping`);
    return;
  }

  // 4) Resolve recipients = group members + the owner.
  const group = await getGroup(link.groupId);
  const groupName = group?.name ?? 'group';
  const recipientEmails = new Set<string>();
  recipientEmails.add(fromEmail); // owner also receives (confirmed decision)
  for (const m of group?.memberEmails ?? []) recipientEmails.add(String(m).toLowerCase());

  // 5) Store the ephemeral latest code (TTL), keyed by group#service.
  const now = Math.floor(Date.now() / 1000);
  await ddb
    .send(
      new PutCommand({
        TableName: CODE_EVENTS_TABLE,
        Item: {
          key: `${link.groupId}#${link.serviceName}`,
          code,
          serviceName: link.serviceName,
          groupName,
          updatedAt: new Date().toISOString(),
          ttl: now + CODE_TTL_SECONDS,
        },
      })
    )
    .catch((e) => console.error('email-ingest: CodeEvents put failed:', e));

  // 6) Push to every recipient's devices.
  const arns = await endpointsForEmails(ddb, sns, recipientEmails, pushCfg);
  const payload = { kind: 'code', service: link.serviceName, group: groupName, code };
  await Promise.allSettled(
    arns.map((arn) => publish(sns, arn, link.serviceName, `${link.serviceName} code: ${code}`, payload))
  );
  // Never log the code itself.
  console.log(`email-ingest: pushed ${link.serviceName} code to ${arns.length} endpoint(s)`);
}

/** UserProfile by email. Scan-with-filter is fine for a small-group app. */
async function findUserByEmail(email: string): Promise<Record<string, any> | null> {
  const out = await ddb.send(
    new ScanCommand({
      TableName: USER_PROFILE_TABLE,
      FilterExpression: '#e = :e',
      ExpressionAttributeNames: { '#e': 'email' },
      ExpressionAttributeValues: { ':e': email },
      Limit: 1,
    })
  );
  return out.Items?.[0] ?? null;
}

async function serviceLinksFor(ownerEmail: string): Promise<Record<string, any>[]> {
  const out = await ddb
    .send(
      new QueryCommand({
        TableName: SERVICE_LINK_TABLE,
        IndexName: process.env.SERVICE_LINK_BY_EMAIL,
        KeyConditionExpression: 'ownerEmail = :e',
        ExpressionAttributeValues: { ':e': ownerEmail },
      })
    )
    .catch((err) => {
      console.error(`service-link lookup failed for ${ownerEmail}:`, err);
      return null;
    });
  return out?.Items ?? [];
}

async function getGroup(groupId: string): Promise<Record<string, any> | null> {
  const out = await ddb
    .send(new GetCommand({ TableName: CODE_GROUP_TABLE, Key: { id: groupId } }))
    .catch((err) => {
      console.error(`group lookup failed for ${groupId}:`, err);
      return null;
    });
  return out?.Item ?? null;
}

function parseRules(matchRules?: string): MatchRules {
  if (!matchRules) return {};
  try {
    return JSON.parse(matchRules) as MatchRules;
  } catch {
    return {};
  }
}

function matches(
  link: Record<string, any>,
  fromEmail: string,
  subject: string,
  body: string
): boolean {
  const rules = parseRules(link.matchRules);
  // The forwarded email's ORIGINAL service sender / subject typically survive in
  // the body of a forward; check from + subject + body for the service marker.
  const haystack = `${fromEmail}\n${subject}\n${body}`.toLowerCase();
  if (rules.fromContains && !haystack.includes(rules.fromContains.toLowerCase())) return false;
  if (rules.subjectContains && !haystack.includes(rules.subjectContains.toLowerCase())) return false;
  // If neither marker is set, the link matches nothing (avoid accidental catch-all).
  return Boolean(rules.fromContains || rules.subjectContains);
}

function extractCode(matchRules: string | undefined, body: string, subject: string): string | null {
  const rules = parseRules(matchRules);
  const text = `${subject}\n${body}`;
  const re = new RegExp(rules.codeRegex || '\\b(\\d{4,8})\\b');
  const m = text.match(re);
  if (!m) return null;
  // Prefer the first capture group if the regex defines one, else the whole match.
  return (m[1] ?? m[0]).trim();
}
