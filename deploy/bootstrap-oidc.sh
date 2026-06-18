#!/usr/bin/env bash
# One-time: deploy the GitHub Actions OIDC role for CI backend deploys.
#
#   ./deploy/bootstrap-oidc.sh
#
# Auth: locally, set AWS_PROFILE=personal-sso (after `aws sso login
# --sso-session personal-sso`). The GitHub OIDC provider already exists in the
# account (created by bin-builder), so CreateOIDCProvider defaults to 'false'.
#
# Prints the DeployRoleArn — set it as the repo variable AWS_DEPLOY_ROLE_ARN
# (Settings → Secrets and variables → Actions → Variables) for the workflow.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK="${STACK:-filght-track-gha-oidc}"
GITHUB_ORG="${GITHUB_ORG:-jroberts64}"
GITHUB_REPO="${GITHUB_REPO:-filght-track}"

PROFILE_ARG=()
if [[ -n "${AWS_PROFILE:-}" ]]; then
  PROFILE_ARG=(--profile "$AWS_PROFILE")
fi

cd "$(dirname "$0")/.."

echo "==> Deploying OIDC role stack ($STACK)…"
aws cloudformation deploy \
  --stack-name "$STACK" \
  --template-file deploy/github-oidc.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  "${PROFILE_ARG[@]}" --region "$REGION" \
  --parameter-overrides \
    GitHubOrg="$GITHUB_ORG" \
    GitHubRepo="$GITHUB_REPO" \
    CreateOIDCProvider=false

echo "==> Role ARN (set as repo variable AWS_DEPLOY_ROLE_ARN):"
aws cloudformation describe-stacks --stack-name "$STACK" \
  "${PROFILE_ARG[@]}" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='DeployRoleArn'].OutputValue" \
  --output text
