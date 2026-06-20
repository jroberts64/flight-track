import { defineBackend } from '@aws-amplify/backend';
import {
  aws_dynamodb as dynamodb,
  aws_iam as iam,
  custom_resources as cr,
} from 'aws-cdk-lib';
import { auth } from './auth/resource';
import { data } from './data/resource';
import { aeroapiLookup } from './functions/aeroapi-lookup/resource';
import { flightRefresh } from './functions/flight-refresh/resource';
import { preTokenGeneration } from './auth/pre-token-generation/resource';

/**
 * FlightTrack backend.
 *
 * Components:
 *  - auth:           Cognito (email sign-in)
 *  - data:           AppSync + DynamoDB models, plus the `lookupFlight` query
 *  - aeroapiLookup:  on-demand AeroAPI proxy (cached)
 *  - flightRefresh:  scheduled (30m) status refresher + push notifier. Also
 *                    creates SNS endpoints lazily (the iOS app just writes a
 *                    DeviceToken row; the endpoint is made on first push).
 *
 * Push is provisioned ONLY when ENABLE_PUSH=true at deploy time (needs an Apple
 * Developer account + APNs .p8 key). Until then the backend deploys fine and
 * DeviceToken rows are stored without an SNS endpoint — so you can ship
 * everything else first.
 */
const backend = defineBackend({
  auth,
  data,
  aeroapiLookup,
  flightRefresh,
  preTokenGeneration,
});

// The pre-token-generation trigger must run as LAMBDA_VERSION_V2_0 to override
// ACCESS-token claims (the default basic version can only touch the ID token).
// Amplify wires the function ARN into LambdaConfig.PreTokenGeneration (V1 key);
// re-point it to PreTokenGenerationConfig with LambdaVersion V2_0.
{
  const cfnUserPool = backend.auth.resources.cfnResources.cfnUserPool;
  const triggerArn = backend.preTokenGeneration.resources.lambda.functionArn;
  cfnUserPool.addPropertyOverride('LambdaConfig.PreTokenGenerationConfig', {
    LambdaArn: triggerArn,
    LambdaVersion: 'V2_0',
  });
  // Remove the V1 key so Cognito uses the V2 config (they are mutually exclusive
  // for the same trigger).
  cfnUserPool.addPropertyDeletionOverride('LambdaConfig.PreTokenGeneration');
}

// --- AeroAPI response cache ----------------------------------------------
const cacheStack = backend.createStack('AeroApiCache');
const cacheTable = new dynamodb.Table(cacheStack, 'AeroApiCacheTable', {
  partitionKey: { name: 'cacheKey', type: dynamodb.AttributeType.STRING },
  billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
  timeToLiveAttribute: 'ttl',
});
cacheTable.grantReadWriteData(backend.aeroapiLookup.resources.lambda);
backend.aeroapiLookup.addEnvironment('CACHE_TABLE_NAME', cacheTable.tableName);

// --- Model table wiring for the push Lambdas -----------------------------
// Amplify exposes each model's DynamoDB table; the Lambdas read/write them
// directly (the data-layer authorization grants are declared in data/resource).
const tables = backend.data.resources.tables;
const flightTable = tables['Flight'];
const deviceTable = tables['DeviceToken'];
const familyTable = tables['FamilyLink'];

// The GSI name Amplify generates for DeviceToken.ownerEmail secondary index.
const DEVICE_BY_EMAIL_GSI = 'deviceTokensByOwnerEmail';

backend.flightRefresh.addEnvironment('FLIGHT_TABLE', flightTable.tableName);
backend.flightRefresh.addEnvironment('DEVICE_TOKEN_TABLE', deviceTable.tableName);
backend.flightRefresh.addEnvironment('FAMILY_LINK_TABLE', familyTable.tableName);
backend.flightRefresh.addEnvironment('DEVICE_TOKEN_BY_EMAIL', DEVICE_BY_EMAIL_GSI);

// Direct table access for the scheduled job. It reads/writes DeviceToken too,
// because it lazily creates SNS endpoints and writes the ARN back.
flightTable.grantReadWriteData(backend.flightRefresh.resources.lambda);
deviceTable.grantReadWriteData(backend.flightRefresh.resources.lambda);
familyTable.grantReadData(backend.flightRefresh.resources.lambda);

// --- SNS push (provisioned only when ENABLE_PUSH=true at deploy time) ------
// Push needs an Apple Developer account + an APNs auth key (.p8). Until you have
// those, deploy WITHOUT push: the rest of the app works and DeviceToken rows are
// stored without an SNS endpoint (PLATFORM_APP_ARN unset). When ready:
//
//   export ENABLE_PUSH=true
//   export APNS_SIGNING_KEY="$(cat AuthKey_XXXX.p8)"   # .p8 contents
//   export APNS_KEY_ID=XXXXXXXXXX
//   export APNS_TEAM_ID=YYYYYYYYYY
//   export APNS_BUNDLE_ID=com.yourorg.flighttrack
//   npx ampx sandbox            # (or pipeline-deploy with these in CI env)
//
// These are read at SYNTH time from the deploy shell — NOT Amplify runtime
// secrets — because the SNS platform application is infrastructure created by
// CloudFormation. The .p8 contents land in the CFN template, so treat the
// deploy environment as sensitive (CI secret store / local shell only).
if (process.env.ENABLE_PUSH === 'true') {
  const APNS_KEY = requireEnv('APNS_SIGNING_KEY');
  const APNS_KEY_ID = requireEnv('APNS_KEY_ID');
  const APNS_TEAM_ID = requireEnv('APNS_TEAM_ID');
  const APNS_BUNDLE_ID = requireEnv('APNS_BUNDLE_ID');

  const pushStack = backend.createStack('Push');

  // SNS mobile-push platform applications have no native CDK L1 construct, so
  // create one via the SDK at deploy time. The .p8 key contents are passed as
  // PlatformCredential; SNS uses APNs token-based auth (key id + team id).
  const platform = process.env.APNS_SANDBOX === 'true' ? 'APNS_SANDBOX' : 'APNS';
  const platformApp = new cr.AwsCustomResource(pushStack, 'ApnsPlatformApp', {
    onCreate: {
      service: 'SNS',
      action: 'createPlatformApplication',
      parameters: {
        Name: 'FlightTrackAPNs',
        Platform: platform,
        Attributes: {
          PlatformPrincipal: APNS_KEY_ID,
          PlatformCredential: APNS_KEY,
          ApplePlatformTeamID: APNS_TEAM_ID,
          ApplePlatformBundleID: APNS_BUNDLE_ID,
        },
      },
      physicalResourceId: cr.PhysicalResourceId.fromResponse('PlatformApplicationArn'),
    },
    onUpdate: {
      service: 'SNS',
      action: 'setPlatformApplicationAttributes',
      parameters: {
        PlatformApplicationArn: new cr.PhysicalResourceIdReference(),
        Attributes: {
          PlatformPrincipal: APNS_KEY_ID,
          PlatformCredential: APNS_KEY,
          ApplePlatformTeamID: APNS_TEAM_ID,
          ApplePlatformBundleID: APNS_BUNDLE_ID,
        },
      },
    },
    onDelete: {
      service: 'SNS',
      action: 'deletePlatformApplication',
      parameters: { PlatformApplicationArn: new cr.PhysicalResourceIdReference() },
    },
    policy: cr.AwsCustomResourcePolicy.fromSdkCalls({
      resources: cr.AwsCustomResourcePolicy.ANY_RESOURCE,
    }),
  });

  const platformArn = platformApp.getResponseField('PlatformApplicationArn');
  backend.flightRefresh.addEnvironment('PLATFORM_APP_ARN', platformArn);

  // The refresh Lambda creates endpoints on demand and publishes to them.
  backend.flightRefresh.resources.lambda.addToRolePolicy(
    new iam.PolicyStatement({
      actions: [
        'sns:CreatePlatformEndpoint',
        'sns:SetEndpointAttributes',
        'sns:GetEndpointAttributes',
        'sns:Publish',
      ],
      resources: [platformArn, `${platformArn}/*`, 'arn:aws:sns:*:*:endpoint/*'],
    })
  );
}

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`ENABLE_PUSH=true but ${name} is not set in the deploy environment`);
  return v;
}
