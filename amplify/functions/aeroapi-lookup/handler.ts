import type { Handler } from 'aws-lambda';
import {
  DynamoDBClient,
} from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
} from '@aws-sdk/lib-dynamodb';

/**
 * AeroAPI lookup handler, invoked as a custom AppSync query resolver.
 *
 * Arguments (from the GraphQL field): { flightNumber: string, date: string }
 *   - flightNumber: e.g. "UA328"
 *   - date: "YYYY-MM-DD" local departure date
 *
 * Returns a normalized FlightLookupResult (see data/resource.ts custom type).
 * Throws on hard errors (missing key, AeroAPI 4xx/5xx) so the client surfaces them.
 */

const AERO_BASE = 'https://aeroapi.flightaware.com/aeroapi';
const TABLE_NAME = process.env.CACHE_TABLE_NAME!; // injected by backend.ts
const CACHE_TTL = parseInt(process.env.CACHE_TTL_SECONDS ?? '300', 10);

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

interface LookupArgs {
  flightNumber: string;
  date: string;
}

interface FlightLookupResult {
  flightNumber: string;
  faFlightId: string | null;
  status: string;
  originIata: string | null;
  destinationIata: string | null;
  scheduledOut: string | null;
  scheduledIn: string | null;
  estimatedOut: string | null;
  estimatedIn: string | null;
  actualOut: string | null;
  actualIn: string | null;
  originGate: string | null;
  destinationGate: string | null;
  originTerminal: string | null;
  destinationTerminal: string | null;
  progressPercent: number | null;
  cached: boolean;
}

export const handler: Handler = async (event): Promise<FlightLookupResult> => {
  const args = (event.arguments ?? event) as LookupArgs;
  const flightNumber = (args.flightNumber ?? '').trim().toUpperCase();
  const date = (args.date ?? '').trim();
  if (!flightNumber || !date) {
    throw new Error('flightNumber and date are required');
  }

  const cacheKey = `${flightNumber}#${date}`;
  const now = Math.floor(Date.now() / 1000);

  // 1. Serve from cache if fresh.
  const cached = await readCache(cacheKey, now);
  if (cached) {
    return { ...cached, cached: true };
  }

  // 2. Call AeroAPI.
  const apiKey = process.env.AERO_API_KEY;
  if (!apiKey) throw new Error('AERO_API_KEY is not configured');

  const start = shiftDate(date, -1);
  const end = shiftDate(date, 2);
  const url = `${AERO_BASE}/flights/${encodeURIComponent(flightNumber)}?start=${start}&end=${end}`;

  const resp = await fetch(url, {
    headers: { 'x-apikey': apiKey, Accept: 'application/json' },
  });
  if (!resp.ok) {
    throw new Error(`AeroAPI returned ${resp.status}`);
  }
  const body = (await resp.json()) as { flights?: AeroFlight[] };
  const flights = body.flights ?? [];
  if (flights.length === 0) {
    throw new Error('No flight found for that flight number/date');
  }

  // Pick the candidate whose scheduled departure is closest to the target date.
  const target = new Date(`${date}T12:00:00Z`).getTime();
  const best = flights.reduce((a, b) => {
    const da = Math.abs(new Date(a.scheduled_out ?? 0).getTime() - target);
    const db = Math.abs(new Date(b.scheduled_out ?? 0).getTime() - target);
    return db < da ? b : a;
  });

  const result = normalize(flightNumber, best);

  // 3. Write to cache with TTL (best-effort; never fail the request on cache write).
  await writeCache(cacheKey, result, now + CACHE_TTL).catch(() => {});

  return result;
};

interface AeroFlight {
  fa_flight_id?: string;
  status?: string;
  progress_percent?: number;
  cancelled?: boolean;
  diverted?: boolean;
  origin?: { code_iata?: string; code?: string };
  destination?: { code_iata?: string; code?: string };
  scheduled_out?: string;
  estimated_out?: string;
  actual_out?: string;
  scheduled_in?: string;
  estimated_in?: string;
  actual_in?: string;
  gate_origin?: string;
  gate_destination?: string;
  terminal_origin?: string;
  terminal_destination?: string;
}

function mapStatus(f: AeroFlight): string {
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

function normalize(flightNumber: string, f: AeroFlight): FlightLookupResult {
  return {
    flightNumber,
    faFlightId: f.fa_flight_id ?? null,
    status: mapStatus(f),
    originIata: f.origin?.code_iata ?? f.origin?.code ?? null,
    destinationIata: f.destination?.code_iata ?? f.destination?.code ?? null,
    scheduledOut: f.scheduled_out ?? null,
    scheduledIn: f.scheduled_in ?? null,
    estimatedOut: f.estimated_out ?? null,
    estimatedIn: f.estimated_in ?? null,
    actualOut: f.actual_out ?? null,
    actualIn: f.actual_in ?? null,
    originGate: f.gate_origin ?? null,
    destinationGate: f.gate_destination ?? null,
    originTerminal: f.terminal_origin ?? null,
    destinationTerminal: f.terminal_destination ?? null,
    progressPercent: f.progress_percent ?? null,
    cached: false,
  };
}

/** "YYYY-MM-DD" -> ISO datetime shifted by `days`, for AeroAPI start/end. */
function shiftDate(date: string, days: number): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString();
}

async function readCache(key: string, now: number): Promise<FlightLookupResult | null> {
  try {
    const out = await ddb.send(
      new GetCommand({ TableName: TABLE_NAME, Key: { cacheKey: key } })
    );
    if (!out.Item) return null;
    // ttl is the absolute expiry epoch; treat as miss if past.
    if (typeof out.Item.ttl === 'number' && out.Item.ttl < now) return null;
    return out.Item.result as FlightLookupResult;
  } catch {
    return null; // cache failures degrade to a live fetch, never an error
  }
}

async function writeCache(key: string, result: FlightLookupResult, ttl: number): Promise<void> {
  await ddb.send(
    new PutCommand({
      TableName: TABLE_NAME,
      Item: { cacheKey: key, result, ttl },
    })
  );
}
