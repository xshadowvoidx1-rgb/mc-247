#!/usr/bin/env bash
# mc-run.sh — one full lifecycle of the 24/7 Minecraft server cycle.
#
# boot (world pack from Release) → serve ~5h10 → save+snapshot+upload (live)
# → stop → dispatch successor via PAT → exit. Hard-kill rail at T+5h35.
set -uo pipefail

REPO="xshadowvoidx1-rgb/mc-247"
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

mkdir -p "$WORK"
cd "$WORK"

# ---------------------------------------------------------------- 1. Java 26
log "installing Temurin 26 JRE"
if [ ! -x "$WORK/jre/bin/java" ]; then
  jre_url="$(curl -s "https://api.adoptium.net/v3/assets/latest/26?image_type=jre&os=linux&arch=x64" | jq -r '.[0].binaries[0].package.link')"
  curl -sL "$jre_url" | tar xz -C "$WORK"
  jdk_dir="$(find "$WORK" -maxdepth 1 -type d -name 'jdk-*' | head -1)"
  mv "$jdk_dir" "$WORK/jre"
fi
JAVA="$WORK/jre/bin/java"
"$JAVA" -version 2>&1 | head -1

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
fi

# ------------------------------------- 3. Minekube Connect plugin + config
# The world-pack tarball predates the connect plugin, so install it from the
# repo checkout (bundle/connect-spigot.jar) whenever it is missing.
if [ ! -f "$SRV/plugins/connect-spigot.jar" ]; then
  log "installing connect-spigot.jar from repo bundle"
  cp "$(dirname "$0")/../bundle/connect-spigot.jar" "$SRV/plugins/"
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
exec 3>console.in   # hold FIFO open for the whole script lifetime

start_server() {
  "$JAVA" -Xms4G -Xmx"$RAM" -jar server.jar nogui < console.in > "$WORK/console.log" 2>&1 &
  JAVA_PID=$!
  log "server started pid=$JAVA_PID"
}

echo "restart" >&3 2>/dev/null || true
start_server

# Wait for "Done" in console log (max 8 min)
log "waiting for server to come up…"
for i in $(seq 1 96); do
  grep -q 'Done (' "$WORK/console.log" 2>/dev/null && break
  sleep 5
done
grep -q 'Done (' "$WORK/console.log" || { log "server never came up"; tail -30 "$WORK/console.log"; exit 3; }
log "SERVER IS UP — public address: ${ENDPOINT}.play.minekube.net"

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
