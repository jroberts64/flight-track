#!/usr/bin/env bash
# Repo-local git credential helper that pins GitHub auth to the `jroberts64`
# account for THIS repository only (the repo lives at jroberts64/flight-track).
#
# Why: `gh` shares one "active account" across all repos. When it's switched to
# another account (e.g. a work account), pushes to this repo are denied with
# HTTP 403. This helper makes `gh` serve the jroberts64 token regardless of the
# global active account, without changing any global git/gh config.
#
# Wiring (one-time, repo-local — done in deploy/setup-git-account.sh):
#   git config --local credential.https://github.com.helper \
#     "!\"$(pwd)/deploy/git-credential-jroberts64.sh\""
#
# git invokes a helper with one arg: get | store | erase. We only handle `get`;
# store/erase are no-ops (gh manages token storage in the keychain).
set -euo pipefail

ACCOUNT="jroberts64"
GH_BIN="${GH_BIN:-$(command -v gh || echo /opt/homebrew/bin/gh)}"

case "${1:-}" in
  get)
    # Select the pinned account, then delegate to gh's own credential helper.
    # `auth switch` is a global side effect; it's the documented way to choose
    # which account gh serves. (If you routinely use another account elsewhere,
    # switch back afterward — or rely on this helper to re-assert on each push.)
    "$GH_BIN" auth switch --user "$ACCOUNT" >/dev/null 2>&1 || true
    exec "$GH_BIN" auth git-credential get
    ;;
  *)
    # store / erase: nothing to do; gh owns token storage.
    exit 0
    ;;
esac
