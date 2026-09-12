#!/usr/bin/env bash
# mc-run.sh — one full lifecycle of the 24/7 Minecraft server cycle.
#
# boot (world pack from Release) → serve ~5h10 → save+snapshot+upload (live)
# → stop → dispatch successor via PAT → exit. Hard-kill rail at T+5h35.
set -uo pipefail

REPO="xshadowvoidx1-rgb/mc-247"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"  # absolute checkout path — the script cd's away below, so relative paths would break
WORK="/home/runner/mc"
SRV="$WORK/server"
API="https://api.github.com"
RAM="${MC_RAM:-10G}"
START="$(date +%s)"
HANDOVER_AT=$((START + 5*3600 + 10*60))  # T+5h10 — graceful window opens
HARDRAIL_AT=$((START + 5*3600 + 35*60))  # T+5h35 — force everything
CRASH_RESTARTS=0

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
gh_api() { curl -s -H "Authorization: token $GH_PAT" -H "Accept: application/vnd.github+json" "$@"; }

# Live status beacon — push milestone text to repo file status.txt so the
# operator can watch the boot in real time (job logs are unreadable mid-run).
beacon() {
  local body msg_sha
  msg_sha="$(gh_api "$API/repos/$REPO/contents/status.txt" | jq -r '.sha // empty')"
  body="{\"message\":\"status beacon\",\"content\":\"$(printf '%s' "$1" | base64 -w0)\""
  [ -n "$msg_sha" ] && body="$body,\"sha\":\"$msg_sha\""
  body="$body}"
  gh_api -X PUT "$API/repos/$REPO/contents/status.txt" -d "$body" >/dev/null || true
}
tail_console() { tail -c 3000 "$WORK/console.log" 2>/dev/null | grep -iE 'connect|minekube|error|exception|done|fail' | tail -15; }

mkdir -p "$WORK"
cd "$WORK"

# ---------------------------------------------------------------- 1. Java 26
log "installing Temurin 26 JRE"
if [ ! -x "$WORK/jre/bin/java" ]; then
  jre_ok=0
  for attempt in 1 2 3; do
    # Adoptium's /v3/assets/ API endpoints are dead (404 as of 2026-09);
    # Temurin binaries live on GitHub release assets instead.
    jre_url="$(gh_api "$API/repos/adoptium/temurin26-binaries/releases/latest" | jq -r '.assets[] | select(.name | test("jre_x64_linux_hotspot.*tar.gz$")) | .browser_download_url' | head -1)"
    if [ -n "$jre_url" ] && [ "$jre_url" != "null" ]; then
      curl -sfL "$jre_url" | tar xz -C "$WORK" && { jre_ok=1; break; }
    fi
    log "JRE install attempt $attempt failed (url=${jre_url:-<empty>})"
    sleep 10
  done
  jdk_dir="$(find "$WORK" -maxdepth 1 -type d -name 'jdk-*' | head -1)"
  if [ "$jre_ok" != "1" ] || [ -z "$jdk_dir" ]; then
    beacon "$(date -u +%H:%M:%S) UTC — FATAL: JRE install failed after 3 attempts (url: ${jre_url:-<empty>})"
    exit 1
  fi
  mv "$jdk_dir" "$WORK/jre"
fi
JAVA="$WORK/jre/bin/java"
if ! "$JAVA" -version 2>&1 | head -1; then
  beacon "$(date -u +%H:%M:%S) UTC — FATAL: java binary broken after install"
  exit 1
fi
beacon "$(date -u +%H:%M:%S) UTC — JRE ready ($("$JAVA" -version 2>&1 | head -1))"

# ------------------------------------------------------- 2. World pack (Release)
if [ ! -d "$SRV" ]; then
  log "downloading world pack from Release 'world-snapshot'"
  REL_JSON="$(gh_api "$API/repos/$REPO/releases/tags/world-snapshot")"
  ASSET_URL="$(echo "$REL_JSON" | jq -r '.assets[] | select(.name | test("world-current")) | .url' | head -1)"
  [ -z "$ASSET_URL" ] && { log "FATAL: no world-current asset on release"; exit 2; }
  mkdir -p "$SRV"
  curl -sL -H "Authorization: token $GH_PAT" -H "Accept: application/octet-stream" \
    -o "$WORK/pack.tar.gz" "$ASSET_URL"
  tar xzf "$WORK/pack.tar.gz" -C "$SRV"
  rm -f "$WORK/pack.tar.gz"
  log "pack extracted: $(du -sh "$SRV" | cut -f1)"
  beacon "$(date -u +%H:%M:%S) UTC — pack extracted $(du -sh "$SRV" | cut -f1)"
fi

# ------------------------------------- 3. Minekube Connect plugin + config
# The world-pack tarball predates the connect plugin, so install it from the
# repo checkout (bundle/connect-spigot.jar) whenever it is missing.
if [ ! -f "$SRV/plugins/connect-spigot.jar" ]; then
  log "installing connect-spigot.jar from repo bundle"
  cp "$REPO_DIR/bundle/connect-spigot.jar" "$SRV/plugins/"
fi
mkdir -p "$SRV/plugins/connect"
cat > "$SRV/plugins/connect/config.yml" <<EOF
endpoint: ${ENDPOINT}
allow-offline-mode-players: true
metrics:
  disabled: true
  uuid: 00000000-0000-0000-0000-000000000001
EOF
export CONNECT_TOKEN

# ------------------------------------------------------------- 4. Start server
cd "$SRV"
rm -f console.in
mkfifo console.in
exec 3<>console.in  # O_RDWR: opening a FIFO write-only would block until a reader appears — but the server starts after this line, so that would deadlock

start_server() {
  "$JAVA" -Xms4G -Xmx"$RAM" -jar server.jar nogui < console.in > "$WORK/console.log" 2>&1 &
  JAVA_PID=$!
  log "server started pid=$JAVA_PID"
}

echo "restart" >&3 2>/dev/null || true
start_server
beacon "$(date -u +%H:%M:%S) UTC — server starting (connect plugin: $(ls "$SRV/plugins/" | grep -c connect-spigot || echo 0) jar, config written)"

# Wait for "Done" in console log (max 8 min)
log "waiting for server to come up…"
for i in $(seq 1 96); do
  grep -q 'Done (' "$WORK/console.log" 2>/dev/null && break
  sleep 5
done
grep -q 'Done (' "$WORK/console.log" || { log "server never came up"; tail -30 "$WORK/console.log"; beacon "$(date -u +%H:%M:%S) UTC — SERVER NEVER CAME UP
$(tail -c 4000 "$WORK/console.log")"; exit 3; }
log "SERVER IS UP — public address: ${ENDPOINT}.play.minekube.net"

# give Connect a minute to register, then beacon what it logged
sleep 60
beacon "$(date -u +%H:%M:%S) UTC — SERVER UP
--- connect/minekube lines ---
$(grep -iE 'connect|minekube|endpoint' "$WORK/console.log" | tail -20)
--- errors ---
$(grep -iE 'error|exception|severe' "$WORK/console.log" | tail -10)"

# ------------------------------------------------- 5. Serve until handover time
while :; do
  now=$(date +%s)
  if ! kill -0 "$JAVA_PID" 2>/dev/null; then
    CRASH_RESTARTS=$((CRASH_RESTARTS + 1))
    if [ "$CRASH_RESTARTS" -gt 3 ]; then log "too many crashes, giving up"; exit 4; fi
    log "server died — restarting (attempt $CRASH_RESTARTS)"
    tail -5 "$WORK/console.log"
    start_server
  fi
  [ "$HANDOVER_NOW" = "true" ] && { log "HANDOVER_NOW set"; break; }
  [ "$now" -ge "$HANDOVER_AT" ] && { log "handover window reached"; break; }
  [ "$now" -ge "$HARDRAIL_AT" ] && { log "HARD RAIL — forcing handover"; break; }
  sleep 20
done

# ------------------------------------------------------------- 6. Handover
handover() {
  log "handover: save-all flush"
  echo "save-all flush" >&3
  sleep 45

  log "handover: snapshotting pack (server still live)"
  rm -f "$WORK/world-current.tar.gz"
  tar czf "$WORK/world-current.tar.gz" --exclude='logs' --exclude='console.in' --exclude='cache' -C "$SRV" .
  log "snapshot size: $(du -sh "$WORK/world-current.tar.gz" | cut -f1)"

  log "handover: rotating Release assets"
  REL_JSON="$(gh_api "$API/repos/$REPO/releases/tags/world-snapshot")"
  REL_ID="$(echo "$REL_JSON" | jq -r '.id')"
  # retire previous prev, demote current → prev, upload new current
  for aid in $(echo "$REL_JSON" | jq -r '.assets[] | select(.name=="world-prev.tar.gz") | .id'); do
    gh_api -X DELETE "$API/repos/$REPO/releases/assets/$aid"
  done
  for aid in $(echo "$REL_JSON" | jq -r '.assets[] | select(.name=="world-current.tar.gz") | .id'); do
    gh_api -X PATCH "$API/repos/$REPO/releases/assets/$aid" -d '{"name":"world-prev.tar.gz"}'
  done
  UP=$(curl -s -X POST \
    -H "Authorization: token $GH_PAT" -H "Content-Type: application/octet-stream" \
    --data-binary @"$WORK/world-current.tar.gz" \
    "https://uploads.github.com/repos/$REPO/releases/$REL_ID/assets?name=world-current.tar.gz")
  echo "$UP" | jq -r '.state, .size' || { log "upload response unclear"; echo "$UP" | head -c 300; }

  log "handover: stopping server"
  echo "stop" >&3
  for i in $(seq 1 30); do kill -0 "$JAVA_PID" 2>/dev/null || break; sleep 2; done
  kill -9 "$JAVA_PID" 2>/dev/null || true

  log "handover: dispatching successor"
  for i in 1 2 3; do
    code=$(gh_api -o /dev/null -w '%{http_code}' -X POST \
      "$API/repos/$REPO/actions/workflows/server.yml/dispatches" -d '{"ref":"main"}')
    [ "$code" = "204" ] && { log "successor dispatched"; return 0; }
    log "dispatch attempt $i failed (HTTP $code)"; sleep 10
  done
  log "dispatch failed — watchdog will heal the chain"
  return 1
}

handover
log "cycle complete, exiting"
