#!/usr/bin/env bash
# Trigger the update workflow from outside GitHub.
#
# GitHub's own scheduler is best-effort: runs can be delayed by 5-30 minutes and
# are sometimes dropped entirely, so a `*/5` cron does not reliably give a
# 5-minute cadence. Calling workflow_dispatch from a real cron (cron-job.org,
# a systemd timer, or the machine you already run) is the only way to get a
# dependable interval — down to 1 minute if you want it.
#
# A dispatch only starts the cheap `check` job; the container build still runs
# only when there is something to do, and `concurrency` prevents pile-ups.
#
# Requires a GitHub token with "Actions: write" on this repository:
#   https://github.com/settings/tokens  (fine-grained: Actions = Read and write)
#
# Usage:
#   export GH_PAT=github_pat_...
#   ./scripts/trigger-workflow.sh
#
# cron example (every minute):
#   * * * * * GH_PAT=github_pat_... /path/to/trigger-workflow.sh >/dev/null 2>&1
set -euo pipefail

REPO="${REPO:-xiryuudev/limusic-bin-aur}"
WORKFLOW="${WORKFLOW:-update.yml}"
REF="${REF:-main}"
TOKEN="${GH_PAT:-${GH_TOKEN:-}}"

[ -n "$TOKEN" ] || {
  echo "GH_PAT is not set (needs a token with 'Actions: write' on ${REPO})" >&2
  exit 1
}

# Replies 204 No Content on success.
status="$(curl -sS -o /tmp/dsh-trigger-body -w '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches" \
  -d "{\"ref\":\"${REF}\"}")"

case "$status" in
  204) echo "dispatched ${WORKFLOW} on ${REF}" >&2 ;;
  401|403)
    echo "authorization failed (HTTP ${status}) — the token lacks 'Actions: write' on ${REPO}" >&2
    cat /tmp/dsh-trigger-body >&2 || true
    exit 1
    ;;
  404)
    echo "workflow not found (HTTP 404) — check ${WORKFLOW} exists on branch ${REF}" >&2
    exit 1
    ;;
  *)
    echo "unexpected HTTP ${status}" >&2
    cat /tmp/dsh-trigger-body >&2 || true
    exit 1
    ;;
esac
