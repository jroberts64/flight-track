#!/usr/bin/env bash
# One-time, REPO-LOCAL setup so git push/pull for this repo authenticates as the
# `jroberts64` GitHub account — even when `gh`'s global active account is set to
# something else. Touches only .git/config (repo-local); no global changes.
#
#   ./deploy/setup-git-account.sh
#
# It pins commit identity and routes GitHub credential lookups through
# deploy/git-credential-jroberts64.sh (which selects the jroberts64 token).
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
HELPER="$REPO_ROOT/deploy/git-credential-jroberts64.sh"

chmod +x "$HELPER"

# Commit identity (local only).
git config --local user.name  "jroberts64"
git config --local user.email "15494545+jroberts64@users.noreply.github.com"

# Credential routing for github.com — LOCAL scope. The leading empty value
# resets any inherited helper list so ours is the only one consulted for pushes
# from this repo.
git config --local --replace-all credential.https://github.com.helper ""
git config --local --add        credential.https://github.com.helper "!\"$HELPER\""

echo "Configured repo-local GitHub auth as jroberts64."
echo "Helper: $HELPER"
