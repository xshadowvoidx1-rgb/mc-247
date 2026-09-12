#!/usr/bin/env bash
# watchdog.sh — babysitter. Fires every 15 min via cron.
# If no server VM is running or queued, and none finished recently, dispatch one.
set -uo pipefail

REPO="xshadowvoidx1-rgb/mc-247"
API="https://api.github.com"
WF="server.yml"

gh_api() { curl -s -H "Authorization: token $GH_PAT" -H "Accept: application/vnd.github+json" "$@"; }
log() { echo "[watchdog $(date -u +%H:%M:%S)] $*"; }

# 1. any active or queued server run?
active=$(gh_api "$API/repos/$REPO/actions/workflows/$WF/runs?status=in_progress" | jq -r '.total_count')
queued=$(gh_api "$API/repos/$REPO/actions/workflows/$WF/runs?status=queued" | jq -r '.total_count')
if [ "${active:-0}" -gt 0 ] || [ "${queued:-0}" -gt 0 ]; then
  log "chain alive (active=$active queued=$queued) — nothing to do"
  exit 0
fi

# 2. debounce: did a run complete in the last 5 minutes? (successor may be queued)
last_completed=$(gh_api "$API/repos/$REPO/actions/workflows/$WF/runs?status=completed&per_page=1" | jq -r '.workflow_runs[0].updated_at // empty')
if [ -n "$last_completed" ]; then
  last_epoch=$(date -d "$last_completed" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  age=$(( now_epoch - last_epoch ))
  if [ "$age" -lt 300 ]; then
    log "run completed ${age}s ago — backing off in case a dispatch is queued"
    exit 0
  fi
fi

# 3. chain is broken — heal it
log "no active server run — dispatching"
code=$(gh_api -o /dev/null -w '%{http_code}' -X POST \
  "$API/repos/$REPO/actions/workflows/$WF/dispatches" -d '{"ref":"main"}')
log "dispatch HTTP $code"
