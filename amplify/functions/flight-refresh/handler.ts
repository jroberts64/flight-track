import type { ScheduledHandler } from 'aws-lambda';
import {
  SNSClient,
  PublishCommand,
  CreatePlatformEndpointCommand,
} from '@aws-sdk/client-sns';
import {
  DynamoDBClient,
} from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient,
  ScanCommand,
  QueryCommand,
  UpdateCommand,
} from '@aws-sdk/lib-dynamodb';
import { Amplify } from 'aws-amplify';
import { generateClient } from 'aws-amplify/data';
import { getAmplifyDataClientConfig } from '@aws-amplify/backend/function/runtime';
import { env } from '$amplify/env/flight-refresh';

/**
 * Scheduled refresher. Reads flights directly from DynamoDB (the model tables),
 * re-queries AeroAPI for near-window flights, diffs, updates, and pushes via SNS.
 *
 * Env (injected by backend.ts):
 *   AERO_API_KEY            — AeroAPI key (secret)
 *   NEAR_WINDOW_HOURS       — only refresh flights within this many hours
 *   FLIGHT_TABLE            — DynamoDB table for the Flight model
 *   DEVICE_TOKEN_TABLE      — DynamoDB table for DeviceToken
 *   DEVICE_TOKEN_BY_EMAIL   — GSI name on DeviceToken.ownerEmail
 *   CONNECTION_TABLE        — DynamoDB table for Connection
 */

const AERO_BASE = 'https://aeroapi.flightaware.com/aeroapi';
const sns = new SNSClient({});
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

const FLIGHT_TABLE = process.env.FLIGHT_TABLE!;
const DEVICE_TABLE = process.env.DEVICE_TOKEN_TABLE!;
const CONNECTION_TABLE = process.env.CONNECTION_TABLE!;
// Amplify data client (IAM-authed via the Lambda's execution role) for calling
// the `publishFlightUpdate` custom mutation. Configured lazily on first use.
let dataClientPromise: Promise<ReturnType<typeof generateClient>> | null = null;
async function getDataClient() {
  if (!dataClientPromise) {
    dataClientPromise = (async () => {
      const { resourceConfig, libraryOptions } = await getAmplifyDataClientConfig(env);
      Amplify.configure(resourceConfig, libraryOptions);
      return generateClient({ authMode: 'iam' });
    })();
  }
  return dataClientPromise;
}
const NEAR_WINDOW_HOURS = parseInt(process.env.NEAR_WINDOW_HOURS ?? '3', 10);
const PLATFORM_APP_ARN = process.env.PLATFORM_APP_ARN; // unset until push is enabled

export const handler: ScheduledHandler = async () => {
  const flights = await scanAll(FLIGHT_TABLE);
  const now = Date.now();
  const windowMs = NEAR_WINDOW_HOURS * 3600 * 1000;

  const near = flights.filter((f) => {
    const dep = ms(f.estimatedOut ?? f.scheduledOut);
    const arr = ms(f.estimatedIn ?? f.scheduledIn);
    // In window if it departs soon, or is currently between dep and arr+window.
    if (dep && dep - now <= windowMs && dep - now >= -windowMs * 4) return true;
    if (dep && arr && now >= dep && now <= arr + windowMs) return true;
    return false;
  });

  console.log(`flight-refresh: ${flights.length} total, ${near.length} in window`);

  for (const flight of near) {
    try {
      await refreshOne(flight);
    } catch (e) {
      console.error(`refresh failed for ${flight.flightNumber}/${flight.id}:`, e);
    }
  }
};

async function refreshOne(flight: Record<string, any>): Promise<void> {
  const live = await fetchAero(flight.flightNumber, flight.departureDate);
  if (!live) return;

  const events = diff(flight, live);
  if (events.length === 0) return;

  // Write through the custom `publishFlightUpdate` AppSync mutation (IAM-signed)
  // rather than a direct DynamoDB write, so the viewer-aware
  // `onConnectionFlightChange` subscription fires for connections watching this
  // flight. Only send fields with a value (partial update on the resolver side).
  await publishFlightUpdate(flight.id, {
    status: live.status,
    estimatedOut: live.estimatedOut ?? flight.estimatedOut ?? null,
    estimatedIn: live.estimatedIn ?? flight.estimatedIn ?? null,
    actualOut: live.actualOut ?? flight.actualOut ?? null,
    actualIn: live.actualIn ?? flight.actualIn ?? null,
    originGate: live.originGate ?? flight.originGate ?? null,
    destinationGate: live.destinationGate ?? flight.destinationGate ?? null,
    originTerminal: live.originTerminal ?? flight.originTerminal ?? null,
    destinationTerminal: live.destinationTerminal ?? flight.destinationTerminal ?? null,
    progressPercent: live.progressPercent ?? flight.progressPercent ?? null,
    lastRefreshedAt: new Date().toISOString(),
  });

  const message = `${flight.flightNumber}: ${events.join('; ')}`;
  const recipients = await recipientsFor(flight);
  await Promise.allSettled(
    recipients.map((arn) => publish(arn, flight.flightNumber, message, flight.id))
  );
  console.log(`pushed "${message}" to ${recipients.length} endpoint(s)`);
}

/** Returns human-readable change events worth notifying about. */
function diff(prev: Record<string, any>, live: AeroNormalized): string[] {
  const events: string[] = [];

  // Status transitions.
  if (prev.status !== live.status) {
    if (live.status === 'CANCELLED') events.push('Flight cancelled');
    else if (live.status === 'DIVERTED') events.push('Flight diverted');
    else if (live.status === 'DEPARTED' || live.status === 'ENROUTE') {
      if (prev.status !== 'DEPARTED' && prev.status !== 'ENROUTE') events.push('Departed');
    } else if (live.status === 'LANDED') events.push('Landed');
  }

  // Delay: estimated departure/arrival moved > 15 min vs scheduled.
  const depDelay = delayMin(prev.scheduledOut, live.estimatedOut);
  if (depDelay !== null && depDelay >= 15 && delayMin(prev.scheduledOut, prev.estimatedOut) !== depDelay) {
    events.push(`Departure delayed ~${depDelay} min`);
  }
  const arrDelay = delayMin(prev.scheduledIn, live.estimatedIn);
  if (arrDelay !== null && arrDelay >= 15 && delayMin(prev.scheduledIn, prev.estimatedIn) !== arrDelay) {
    events.push(`Arrival delayed ~${arrDelay} min`);
  }

  // Gate / terminal changes.
  if (live.originGate && live.originGate !== prev.originGate) {
    events.push(`Departure gate now ${live.originGate}`);
  }
  if (live.destinationGate && live.destinationGate !== prev.destinationGate) {
    events.push(`Arrival gate now ${live.destinationGate}`);
  }
  if (live.originTerminal && live.originTerminal !== prev.originTerminal) {
    events.push(`Departure terminal now ${live.originTerminal}`);
  }
  if (live.destinationTerminal && live.destinationTerminal !== prev.destinationTerminal) {
    events.push(`Arrival terminal now ${live.destinationTerminal}`);
  }

  return events;
}

/**
 * Writes a flight change via the custom `publishFlightUpdate` AppSync mutation
 * (IAM-authed Amplify data client). Going through AppSync rather than a direct
 * DynamoDB write is what fires the `onConnectionFlightChange` subscription for
 * viewers. Only non-null fields are sent (partial update on the resolver side).
 */
async function publishFlightUpdate(
  id: string,
  fields: Record<string, string | number | null>
): Promise<void> {
  const args: Record<string, string | number> = { id };
  for (const [k, v] of Object.entries(fields)) {
    if (v !== null && v !== undefined) args[k] = v;
  }

  const query = `mutation Publish(
    $id: ID!, $status: String, $estimatedOut: String, $estimatedIn: String,
    $actualOut: String, $actualIn: String, $originGate: String,
    $destinationGate: String, $originTerminal: String, $destinationTerminal: String,
    $progressPercent: Int, $lastRefreshedAt: String
  ) {
    publishFlightUpdate(
      id: $id, status: $status, estimatedOut: $estimatedOut, estimatedIn: $estimatedIn,
      actualOut: $actualOut, actualIn: $actualIn, originGate: $originGate,
      destinationGate: $destinationGate, originTerminal: $originTerminal,
      destinationTerminal: $destinationTerminal, progressPercent: $progressPercent,
      lastRefreshedAt: $lastRefreshedAt
    ) {
      id ownerEmail flightNumber status originGate destinationGate originTerminal
      destinationTerminal estimatedOut estimatedIn actualOut actualIn
      progressPercent lastRefreshedAt viewers
    }
  }`;
  // ^ must select `viewers` (the subscription filter field) + the fields the
  // app's subscription reads, or onConnectionFlightChange won't fire.

  try {
    const client = await getDataClient();
    const res: any = await (client as any).graphql({ query, variables: args });
    if (res?.errors) console.error('publishFlightUpdate errors:', JSON.stringify(res.errors));
  } catch (e) {
    console.error('publishFlightUpdate failed:', e);
  }
}

/** SNS endpoint ARNs for the flight owner + accepted connections. */
async function recipientsFor(flight: Record<string, any>): Promise<string[]> {
  const ownerEmail = (flight.ownerEmail ?? flight.profileEmail ?? '').toLowerCase();
  const emails = new Set<string>();
  if (ownerEmail) emails.add(ownerEmail);

  // Owner email may not be denormalized on Flight; fall back via profile lookup
  // is skipped for brevity — see note in README. If absent, we still notify any
  // connections that reference the owner once email is present.
  if (ownerEmail) {
    const links = await scanAll(CONNECTION_TABLE);
    for (const l of links) {
      if (l.status !== 'ACCEPTED') continue;
      const a = (l.inviterEmail ?? '').toLowerCase();
      const b = (l.inviteeEmail ?? '').toLowerCase();
      if (a === ownerEmail) emails.add(b);
      if (b === ownerEmail) emails.add(a);
    }
  }

  const arns: string[] = [];
  for (const email of emails) {
    const res = await ddb
      .send(
        new QueryCommand({
          TableName: DEVICE_TABLE,
          IndexName: process.env.DEVICE_TOKEN_BY_EMAIL,
          KeyConditionExpression: 'ownerEmail = :e',
          ExpressionAttributeValues: { ':e': email },
        })
      )
      .catch((err) => {
        console.error(`device lookup failed for ${email}:`, err);
        return null;
      });
    for (const item of res?.Items ?? []) {
      const arn = await ensureEndpoint(item);
      if (arn) arns.push(arn);
    }
  }
  return arns;
}

/**
 * Returns the device's SNS endpoint ARN, creating it lazily on first use.
 * The iOS app writes DeviceToken rows with no endpoint; we mint one here from
 * the raw APNs token, persist it, and reuse it on subsequent runs.
 */
async function ensureEndpoint(device: Record<string, any>): Promise<string | null> {
  if (device.snsEndpointArn) return device.snsEndpointArn as string;
  if (!PLATFORM_APP_ARN || !device.token) return null;
  try {
    const created = await sns.send(
      new CreatePlatformEndpointCommand({
        PlatformApplicationArn: PLATFORM_APP_ARN,
        Token: device.token,
        CustomUserData: device.ownerEmail,
      })
    );
    const arn = created.EndpointArn!;
    await ddb.send(
      new UpdateCommand({
        TableName: DEVICE_TABLE,
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

async function publish(
  endpointArn: string,
  title: string,
  body: string,
  flightId?: string
): Promise<void> {
  const apns = JSON.stringify({
    // `content-available: 1` lets iOS wake the app in the background to refresh
    // before the user opens it; the alert still shows. `flightId` lets the app
    // refresh just the changed flight (falls back to a full reload if absent).
    aps: { alert: { title, body }, sound: 'default', 'content-available': 1 },
    flightId,
  });
  await sns.send(
    new PublishCommand({
      TargetArn: endpointArn,
      MessageStructure: 'json',
      Message: JSON.stringify({ default: body, APNS: apns, APNS_SANDBOX: apns }),
    })
  );
}

// --- AeroAPI (shares the same upstream as aeroapi-lookup) -----------------

interface AeroNormalized {
  status: string;
  estimatedOut: string | null;
  estimatedIn: string | null;
  actualOut: string | null;
  actualIn: string | null;
  originGate: string | null;
  destinationGate: string | null;
  originTerminal: string | null;
  destinationTerminal: string | null;
  progressPercent: number | null;
}

async function fetchAero(flightNumber: string, date: string): Promise<AeroNormalized | null> {
  const apiKey = process.env.AERO_API_KEY;
  if (!apiKey) return null;
  const start = shiftDate(date, -1);
  const end = shiftDate(date, 2);
  const url = `${AERO_BASE}/flights/${encodeURIComponent(flightNumber)}?start=${start}&end=${end}`;
  const resp = await fetch(url, { headers: { 'x-apikey': apiKey, Accept: 'application/json' } });
  if (!resp.ok) {
    console.error(`AeroAPI ${resp.status} for ${flightNumber}`);
    return null;
  }
  const body = (await resp.json()) as { flights?: any[] };
  const flights = body.flights ?? [];
  if (flights.length === 0) return null;
  const target = new Date(`${date}T12:00:00Z`).getTime();
  const f = flights.reduce((a, b) =>
    Math.abs(new Date(b.scheduled_out ?? 0).getTime() - target) <
    Math.abs(new Date(a.scheduled_out ?? 0).getTime() - target)
      ? b
      : a
  );
  return {
    status: mapStatus(f),
    estimatedOut: f.estimated_out ?? null,
    estimatedIn: f.estimated_in ?? null,
    actualOut: f.actual_out ?? null,
    actualIn: f.actual_in ?? null,
    originGate: f.gate_origin ?? null,
    destinationGate: f.gate_destination ?? null,
    originTerminal: f.terminal_origin ?? null,
    destinationTerminal: f.terminal_destination ?? null,
    progressPercent: f.progress_percent ?? null,
  };
}

function mapStatus(f: any): string {
  if (f.cancelled) return 'CANCELLED';
  if (f.diverted) return 'DIVERTED';
  const s = (f.status ?? '').toLowerCase();
  if (s.includes('scheduled')) return 'SCHEDULED';
  if (s.includes('boarding')) return 'BOARDING';
  if (s.includes('en route') || s.includes('airborne')) return 'ENROUTE';
  if (s.includes('landed') || s.includes('arrived')) return 'LANDED';
  if (s.includes('delayed')) return 'DELAYED';
  if (s.includes('taxi') || s.includes('departed')) return 'DEPARTED';
  return 'UNKNOWN';
}

// --- helpers --------------------------------------------------------------

function ms(iso: string | null | undefined): number | null {
  if (!iso) return null;
  const t = new Date(iso).getTime();
  return Number.isNaN(t) ? null : t;
}

/** Minutes the estimate is later than the schedule (null if either missing). */
function delayMin(scheduled: string | null | undefined, estimated: string | null | undefined): number | null {
  const s = ms(scheduled);
  const e = ms(estimated);
  if (s === null || e === null) return null;
  return Math.round((e - s) / 60000);
}

function shiftDate(date: string, days: number): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString();
}

async function scanAll(table: string): Promise<Record<string, any>[]> {
  const items: Record<string, any>[] = [];
  let ExclusiveStartKey: Record<string, any> | undefined;
  do {
    const out = await ddb.send(new ScanCommand({ TableName: table, ExclusiveStartKey }));
    items.push(...(out.Items ?? []));
    ExclusiveStartKey = out.LastEvaluatedKey;
  } while (ExclusiveStartKey);
  return items;
}
