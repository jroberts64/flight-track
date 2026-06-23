import { defineBackend } from '@aws-amplify/backend';
import {
  Duration,
  aws_dynamodb as dynamodb,
  aws_iam as iam,
  aws_s3 as s3,
  aws_s3_notifications as s3n,
  custom_resources as cr,
} from 'aws-cdk-lib';
import { auth } from './auth/resource';
import { data } from './data/resource';
import { aeroapiLookup } from './functions/aeroapi-lookup/resource';
import { flightRefresh } from './functions/flight-refresh/resource';
import { emailIngest } from './functions/email-ingest/resource';
import { preTokenGeneration } from './auth/pre-token-generation/resource';

/** Inbound address codes are forwarded to (SES inbound on the app subdomain). */
const INBOUND_RECIPIENT = 'decode@app.jack-roberts.com';

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
  emailIngest,
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
const connectionTable = tables['Connection'];
const userProfileTable = tables['UserProfile'];
const codeGroupTable = tables['CodeGroup'];
const serviceLinkTable = tables['ServiceLink'];

// The GSI names Amplify generates for the *.ownerEmail secondary indexes.
const DEVICE_BY_EMAIL_GSI = 'deviceTokensByOwnerEmail';
const SERVICE_LINK_BY_EMAIL_GSI = 'serviceLinksByOwnerEmail';

backend.flightRefresh.addEnvironment('FLIGHT_TABLE', flightTable.tableName);
backend.flightRefresh.addEnvironment('DEVICE_TOKEN_TABLE', deviceTable.tableName);
backend.flightRefresh.addEnvironment('CONNECTION_TABLE', connectionTable.tableName);
backend.flightRefresh.addEnvironment('DEVICE_TOKEN_BY_EMAIL', DEVICE_BY_EMAIL_GSI);

// Direct table access for the scheduled job. It reads/writes DeviceToken too,
// because it lazily creates SNS endpoints and writes the ARN back.
flightTable.grantReadWriteData(backend.flightRefresh.resources.lambda);
deviceTable.grantReadWriteData(backend.flightRefresh.resources.lambda);
connectionTable.grantReadData(backend.flightRefresh.resources.lambda);

// grantReadWriteData covers the table ARN but NOT secondary indexes. The refresh
// Lambda Queries the deviceTokensByOwnerEmail GSI to find recipients, which needs
// dynamodb:Query on the table/.../index/* ARN. Grant it explicitly.
backend.flightRefresh.resources.lambda.addToRolePolicy(
  new iam.PolicyStatement({
    actions: ['dynamodb:Query'],
    resources: [
      `${deviceTable.tableArn}/index/*`,
      `${flightTable.tableArn}/index/*`,
      `${connectionTable.tableArn}/index/*`,
    ],
  })
);

// --- Inbound email → code push (SES inbound → S3 → email-ingest Lambda) ----
// SES inbound on the app.jack-roberts.com subdomain writes forwarded code
// emails to S3; the object-created event triggers email-ingest, which parses
// the email, validates the sender, matches a ServiceLink, extracts the code,
// and pushes it to the linked CodeGroup. The subdomain MX record + SES identity
// verification + activating the receipt rule set are MANUAL DNS/SES steps (see
// the plan / README) — CloudFormation owns only the bucket, rule, table, grants.
// All inbound-email infra lives in the DATA stack — same as the model tables
// and the email-ingest lambda (pinned via resourceGroupName:'data'). Keeping
// bucket + lambda + tables co-located means the S3 ObjectCreated notification
// and the lambda's read-grant/env never cross a nested-stack boundary, which
// would be a circular dependency (aws-cdk#5760). Drop the separate stack.
const ingestLambda = backend.emailIngest.resources.lambda;
const ingestScope = ingestLambda.stack; // the data nested stack

// Ephemeral "latest code" store. Custom table (not an Amplify model) so we get
// DynamoDB TTL and keep the secret out of the AppSync-queryable graph.
const codeEventsTable = new dynamodb.Table(ingestScope, 'CodeEventsTable', {
  partitionKey: { name: 'key', type: dynamodb.AttributeType.STRING },
  billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
  timeToLiveAttribute: 'ttl',
});

// Raw inbound emails. Codes rest here briefly: encrypt, block public access,
// and expire objects after 1 day to minimize a secret's lifetime at rest.
const inboundBucket = new s3.Bucket(ingestScope, 'InboundEmailBucket', {
  encryption: s3.BucketEncryption.S3_MANAGED,
  blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
  enforceSSL: true,
  lifecycleRules: [{ expiration: Duration.days(1) }],
});
// SES must be allowed to write inbound messages to the bucket.
inboundBucket.addToResourcePolicy(
  new iam.PolicyStatement({
    principals: [new iam.ServicePrincipal('ses.amazonaws.com')],
    actions: ['s3:PutObject'],
    resources: [`${inboundBucket.bucketArn}/*`],
    conditions: { StringEquals: { 'aws:Referer': backend.stack.account } },
  })
);

// SES receipt rule: NOT managed here. Only one receipt rule set is ACTIVE per
// region, and WorkMail already owns the active set (INBOUND_MAIL) for
// jack-roberts.com — creating/activating a competing set would break WorkMail
// inbound mail. So the rule routing `decode@app.jack-roberts.com` to this
// bucket is added into the existing INBOUND_MAIL set out-of-band (CLI), not via
// CloudFormation. The bucket + SES PutObject permission below are all CDK owns.
// (Manual rule: ses create-receipt-rule --rule-set-name INBOUND_MAIL …)

// S3 object-created → email-ingest Lambda.
inboundBucket.addEventNotification(
  s3.EventType.OBJECT_CREATED,
  new s3n.LambdaDestination(ingestLambda),
  { prefix: 'inbound/' }
);
inboundBucket.grantRead(ingestLambda);

// Table access (least privilege): read the lookup tables; write DeviceToken
// (endpoint ARN write-back) and CodeEvents.
userProfileTable.grantReadData(ingestLambda);
serviceLinkTable.grantReadData(ingestLambda);
codeGroupTable.grantReadData(ingestLambda);
deviceTable.grantReadWriteData(ingestLambda);
codeEventsTable.grantReadWriteData(ingestLambda);

// GSI Query grants (grantReadData does not cover secondary indexes).
ingestLambda.addToRolePolicy(
  new iam.PolicyStatement({
    actions: ['dynamodb:Query'],
    resources: [
      `${serviceLinkTable.tableArn}/index/*`,
      `${deviceTable.tableArn}/index/*`,
    ],
  })
);

backend.emailIngest.addEnvironment('USER_PROFILE_TABLE', userProfileTable.tableName);
backend.emailIngest.addEnvironment('SERVICE_LINK_TABLE', serviceLinkTable.tableName);
backend.emailIngest.addEnvironment('SERVICE_LINK_BY_EMAIL', SERVICE_LINK_BY_EMAIL_GSI);
backend.emailIngest.addEnvironment('CODE_GROUP_TABLE', codeGroupTable.tableName);
backend.emailIngest.addEnvironment('CODE_EVENTS_TABLE', codeEventsTable.tableName);
backend.emailIngest.addEnvironment('DEVICE_TOKEN_TABLE', deviceTable.tableName);
backend.emailIngest.addEnvironment('DEVICE_TOKEN_BY_EMAIL', DEVICE_BY_EMAIL_GSI);

// --- SNS push (provisioned by default; set ENABLE_PUSH=false to skip) ------
// Push is now ON by default — provisioned unless ENABLE_PUSH is explicitly set
// to "false". It needs an Apple Developer account + an APNs auth key (.p8), so
// the deploy shell must export the APNs vars (typically `source
// ~/.apple-developer/flighttrack.env`):
//
//   export APNS_SIGNING_KEY="$(cat AuthKey_XXXX.p8)"   # .p8 contents
//   export APNS_KEY_ID=XXXXXXXXXX
//   export APNS_TEAM_ID=YYYYYYYYYY
//   export APNS_BUNDLE_ID=com.yourorg.flighttrack
//   npx ampx sandbox            # (or pipeline-deploy with these in CI env)
//
// To deploy WITHOUT push (no APNs key available, e.g. a CI run that lacks the
// secrets): `export ENABLE_PUSH=false`. Then DeviceToken rows are stored
// without an SNS endpoint (PLATFORM_APP_ARN unset) and nothing is sent.
//
// These are read at SYNTH time from the deploy shell — NOT Amplify runtime
// secrets — because the SNS platform application is infrastructure created by
// CloudFormation. The .p8 contents land in the CFN template, so treat the
// deploy environment as sensitive (CI secret store / local shell only).
if (process.env.ENABLE_PUSH !== 'false') {
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
  backend.emailIngest.addEnvironment('PLATFORM_APP_ARN', platformArn);

  // Both push Lambdas create endpoints on demand and publish to them.
  const snsPushPolicy = new iam.PolicyStatement({
    actions: [
      'sns:CreatePlatformEndpoint',
      'sns:SetEndpointAttributes',
      'sns:GetEndpointAttributes',
      'sns:Publish',
    ],
    resources: [platformArn, `${platformArn}/*`, 'arn:aws:sns:*:*:endpoint/*'],
  });
  backend.flightRefresh.resources.lambda.addToRolePolicy(snsPushPolicy);
  backend.emailIngest.resources.lambda.addToRolePolicy(snsPushPolicy);
}

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`ENABLE_PUSH=true but ${name} is not set in the deploy environment`);
  return v;
}
