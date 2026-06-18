import { defineBackend } from '@aws-amplify/backend';
import { aws_dynamodb as dynamodb } from 'aws-cdk-lib';
import { auth } from './auth/resource';
import { data } from './data/resource';
import { aeroapiLookup } from './functions/aeroapi-lookup/resource';

/**
 * FlightTrack backend.
 *
 * Components:
 *  - auth:  Cognito (email sign-in)
 *  - data:  AppSync + DynamoDB models, plus the `lookupFlight` custom query
 *  - aeroapiLookup: Lambda that proxies FlightAware AeroAPI server-side
 *
 * This file also provisions a DynamoDB cache table for AeroAPI responses and
 * wires it to the Lambda (least-privilege read/write + table name env var).
 */
const backend = defineBackend({
  auth,
  data,
  aeroapiLookup,
});

// --- AeroAPI response cache ----------------------------------------------
// Keyed by `${flightNumber}#${date}`, with a DynamoDB TTL so stale entries
// auto-expire. This keeps repeated lookups (multiple family members watching
// one flight, or client polling) from each hitting the paid AeroAPI.
const cacheStack = backend.createStack('AeroApiCache');

const cacheTable = new dynamodb.Table(cacheStack, 'AeroApiCacheTable', {
  partitionKey: { name: 'cacheKey', type: dynamodb.AttributeType.STRING },
  billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
  timeToLiveAttribute: 'ttl',
});

const lambda = backend.aeroapiLookup.resources.lambda;
cacheTable.grantReadWriteData(lambda);
backend.aeroapiLookup.addEnvironment('CACHE_TABLE_NAME', cacheTable.tableName);

/**
 * Next step (see README "Hardening"):
 *  - Add a scheduled function to refresh upcoming flights + send push.
 */
