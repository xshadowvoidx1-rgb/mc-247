#!/usr/bin/env bash
# watchdog.sh — babysitter. Fires every 15 min via cron.
# If no server VM is running or queued, and none finished recently, dispatch one.
set -uo pipefail

REPO="xshadowvoidx1-rgb/mc-247"
API="https://api.github.com"
WF="server.yml"

gh_api() { curl -s -H "Authorization: token $GH_PAT" -H "Accept: application/vnd.github+json" "$@"; }
log() { echo "[watchdog $(date -u +%H:%M:%S)] $*"; }

# 1. any active or queued server run? (graceful handovers leave a queued
#    successor behind — that means the chain is healthy)
active=$(gh_api "$API/repos/$REPO/actions/workflows/$WF/runs?status=in_progress" | jq -r '.total_count')
queued=$(gh_api "$API/repos/$REPO/actions/workflows/$WF/runs?status=queued" | jq -r '.total_count')
if [ "${active:-0}" -gt 0 ] || [ "${queued:-0}" -gt 0 ]; then
  log "chain alive (active=$active queued=$queued) — nothing to do"
  exit 0
fi

# 2. chain is broken — heal it. (No debounce: with the workflow_run trigger we
# fire exactly at completion; a queued successor is already visible in step 1.)
log "no active server run — dispatching"
code=$(gh_api -o /dev/null -w '%{http_code}' -X POST \
  "$API/repos/$REPO/actions/workflows/$WF/dispatches" -d '{"ref":"main"}')
log "dispatch HTTP $code"
