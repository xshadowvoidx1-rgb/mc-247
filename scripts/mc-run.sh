#!/usr/bin/env bash
# mc-run.sh — one full lifecycle of the 24/7 Folia survival server cycle.
#
# Architecture (Folia can't run the Connect plugin, so a Velocity proxy fronts it):
#   players → minekube edge → Velocity (connect-velocity plugin, port 25565)
#           → Folia backend (127.0.0.1:25566, modern forwarding, survival, offline)
#
# boot (snapshot from Release, fresh install if none) → serve ~5h10 → snapshot
# (live) → stop → dispatch successor via PAT → exit. Hard-kill rail at T+5h35.
set -uo pipefail

REPO="xshadowvoidx1-rgb/mc-247"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"  # absolute checkout path — the script cd's away below
WORK="/home/runner/mc"
SRV="$WORK/server"
VEL="$WORK/velocity"
API="https://api.github.com"
RAM="${MC_RAM:-8G}"
START="$(date +%s)"
HANDOVER_AT=$((START + 5*3600 + 10*60))  # T+5h10 — graceful window opens
HARDRAIL_AT=$((START + 5*3600 + 35*60))  # T+5h35 — force everything
CRASH_RESTARTS=0
FORWARD_SECRET="${FORWARD_SECRET:-wahid-survival-2026}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
gh_api() { curl -s -H "Authorization: token $GH_PAT" -H "Accept: application/vnd.github+json" "$@"; }

# Diagnostics channel — a SEPARATE repo file (velocity-status.txt) that is
# overwritten only by explicit diag() calls, so it survives the status.txt
# beacon churn and can be read while the server is running.
diag() {
  local body msg_sha
  msg_sha="$(gh_api "$API/repos/$REPO/contents/velocity-status.txt" | jq -r '.sha // empty')"
  body="{\"message\":\"velocity diag\",\"content\":\"$(printf '%s' "$1" | base64 -w0)\""
  [ -n "$msg_sha" ] && body="$body,\"sha\":\"$msg_sha\""
  body="$body}"
  gh_api -X PUT "$API/repos/$REPO/contents/velocity-status.txt" -d "$body" >/dev/null || true
}

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

# ------------------------------------------- 2. Restore snapshot (if any)
if [ ! -d "$SRV" ] || [ ! -d "$VEL" ]; then
  REL_JSON="$(gh_api "$API/repos/$REPO/releases/tags/world-snapshot")"
  ASSET_URL="$(echo "$REL_JSON" | jq -r '.assets[] | select(.name=="world-current.tar.gz") | .url' | head -1)"
  if [ -n "$ASSET_URL" ] && [ "$ASSET_URL" != "null" ]; then
    log "restoring world snapshot from Release"
    mkdir -p "$SRV" "$VEL"
    curl -sL -H "Authorization: token $GH_PAT" -H "Accept: application/octet-stream" \
      -o "$WORK/snap.tar.gz" "$ASSET_URL"
    tar xzf "$WORK/snap.tar.gz" -C "$WORK" server velocity
    rm -f "$WORK/snap.tar.gz"
    log "snapshot restored: $(du -sh "$SRV" | cut -f1) server"
    beacon "$(date -u +%H:%M:%S) UTC — snapshot restored $(du -sh "$SRV" | cut -f1)"
  fi
fi

# ----------------------------------- 3. Fresh install (Folia + Velocity)
if [ ! -f "$SRV/server.jar" ]; then
  log "fresh install: Folia 1.21.11 + Velocity 4.1.1 + connect-velocity 0.15.13"
  mkdir -p "$SRV" "$VEL/plugins/connect"

  curl -sfL -o "$SRV/server.jar" \
    "https://fill-data.papermc.io/v1/objects/43f6cec8d96e6172cb646520039067d71fabd87600580cc0d676ee377d649a94/folia-1.21.11-1.jar" \
    || { beacon "$(date -u +%H:%M:%S) UTC — FATAL: folia jar download failed"; exit 1; }
  curl -sfL -o "$VEL/velocity.jar" \
    "https://fill-data.papermc.io/v1/objects/846411d2d0560fed0f23496ffb89681be528d2c0650ecdcf21724d2d7bd9c1ee/velocity-4.1.1-24.jar" \
    || { beacon "$(date -u +%H:%M:%S) UTC — FATAL: velocity jar download failed"; exit 1; }
  curl -sfL -o "$VEL/plugins/connect-velocity.jar" \
    "https://github.com/minekube/connect-java/releases/download/0.15.13/connect-velocity.jar" \
    || { beacon "$(date -u +%H:%M:%S) UTC — FATAL: connect-velocity jar download failed"; exit 1; }
fi

# ------------------------------------------- 3b. Configs (EVERY boot)
# The release snapshot archives $SRV *and* $VEL, so a config written once on a
# fresh install gets restored forever — including a broken one. Rewrite all of
# them on every boot so the script, not the snapshot, is the source of truth.
mkdir -p "$SRV/config" "$VEL/plugins/connect"

  # Folia backend: survival, offline, behind velocity (port 25566)
  cat > "$SRV/server.properties" <<EOF
server-port=25566
online-mode=false
gamemode=survival
difficulty=normal
motd=Shadows In The Dark §7— Survival (Folia)
level-name=world
level-seed=712262452098460
spawn-protection=0
view-distance=8
simulation-distance=6
max-players=100
white-list=false
enforce-secure-profile=false
enable-command-block=true
EOF
  echo "eula=true" > "$SRV/eula.txt"

  # modern forwarding secret shared by velocity + folia
  printf '%s' "$FORWARD_SECRET" > "$VEL/forwarding.secret"
  mkdir -p "$SRV/config"
  cat > "$SRV/config/paper-global.yml" <<EOF
_prose:
  header: managed by mc-run.sh — do not hand-edit
proxies:
  bungee-cord:
    online-mode: true
  velocity:
    enabled: true
    online-mode: false
    secret: $FORWARD_SECRET
EOF

  # operator pre-opped via offline UUID (cracked client identity)
  cat > "$SRV/ops.json" <<'EOF'
[
  {
    "uuid": "c3a8e7c8-2620-3faf-9f55-0aeb6055570e",
    "name": "xxShadowVoidxx",
    "level": 4,
    "bypassesPlayerLimit": true
  }
]
EOF

  # Velocity proxy: offline mode, forwards to folia backend
  cat > "$VEL/velocity.toml" <<EOF
config-version = "2.7"
bind = "0.0.0.0:25565"
# Velocity 4.x parses motd as MiniMessage — legacy § codes are a hard config
# error ("Velocity will not start up until the errors are resolved").
motd = "Shadows In The Dark <gray>— Survival"
show-max-players = 100
online-mode = false
player-info-forwarding-mode = "modern"
forwarding-secret-file = "forwarding.secret"
force-key-authentication = false

[servers]
folia = "127.0.0.1:25566"
try = [
  "folia"
]

[forced-hosts]

[advanced]
compression-threshold = 256

[query]
enabled = false
EOF

  # Minekube Connect tunnel config — bash expands ${ENDPOINT} at write time
  # (same as the old spigot setup; the plugin does NOT resolve placeholders)
  cat > "$VEL/plugins/connect/config.yml" <<EOF
endpoint: ${ENDPOINT}
allow-offline-mode-players: true
metrics:
  disabled: true
  uuid: 00000000-0000-0000-0000-000000000001
EOF
beacon "$(date -u +%H:%M:%S) UTC — configs written (folia+velocity+connect)"

# ------------------------------- 3c. Proxy plugins (ViaVersion/ViaBackwards)
# Version translation belongs on the PROXY: Velocity rewrites old-client packets
# up to 1.21.11 before they reach Folia, so the backend stays stock. Guarded
# independently of server.jar — a snapshot restore carries $VEL, but a plugin
# added after that snapshot was taken still has to be fetched once.
for spec in \
  "ViaVersion.jar|https://cdn.modrinth.com/data/P1OZGk5p/versions/FaishMnD/ViaVersion-5.12.0.jar" \
  "ViaBackwards.jar|https://cdn.modrinth.com/data/NpvuJQoq/versions/SxGhdsPK/ViaBackwards-5.12.0.jar"
do
  vname="${spec%%|*}"; vurl="${spec#*|}"
  [ -f "$VEL/plugins/$vname" ] && continue
  log "downloading $vname"
  curl -sfL -o "$VEL/plugins/$vname" "$vurl" \
    || { beacon "$(date -u +%H:%M:%S) UTC — FATAL: $vname download failed"; exit 1; }
done
# CONNECT_TOKEN must be exported regardless of fresh-install vs snapshot restore
export CONNECT_TOKEN

# ------------------------------------------------------------- 4. Start stack
cd "$SRV"
rm -f console.in
mkfifo console.in
exec 3<>console.in  # O_RDWR: opening a FIFO write-only would block until a reader appears — but the server starts after this line, so that would deadlock

start_folia() {
  "$JAVA" -Xms2G -Xmx"$RAM" -jar server.jar nogui < console.in > "$WORK/console.log" 2>&1 &
  FOLIA_PID=$!
  log "folia started pid=$FOLIA_PID"
}
start_velocity() {
  # MUST run from $VEL — Velocity resolves velocity.toml, forwarding.secret and
  # plugins/ from its working directory. From $SRV it silently generates a
  # default config (forwarding off, no connect endpoint) and the tunnel never
  # registers.
  (cd "$VEL" && exec "$JAVA" -Xms256M -Xmx512M -jar velocity.jar) > "$WORK/velocity.log" 2>&1 &
  VEL_PID=$!
  log "velocity started pid=$VEL_PID"
}

start_folia
beacon "$(date -u +%H:%M:%S) UTC — folia starting (survival, offline, 25566)"

# Wait for Folia "Done" (max 10 min — first boot generates the world)
log "waiting for folia to come up…"
for i in $(seq 1 120); do
  grep -q 'Done (' "$WORK/console.log" 2>/dev/null && break
  sleep 5
done
grep -q 'Done (' "$WORK/console.log" || {
  beacon "$(date -u +%H:%M:%S) UTC — FOLIA NEVER CAME UP
$(tail -c 4000 "$WORK/console.log")"
  exit 3
}
log "FOLIA IS UP"

start_velocity
# give Connect time to register the tunnel, then write a full diagnostic dump
# to velocity-status.txt (status.txt is too transient to debug from).
for i in $(seq 1 24); do
  grep -qi 'registered\|tunnel\|endpoint\|error\|exception\|fail' "$WORK/velocity.log" 2>/dev/null && break
  sleep 5
done
sleep 30
diag "$(date -u +%H:%M:%S) UTC — velocity diag
=== env ===
CONNECT_TOKEN set: $([ -n "${CONNECT_TOKEN:-}" ] && echo yes || echo NO)
ENDPOINT: ${ENDPOINT:-<unset>}
=== $VEL layout ===
$(ls -la "$VEL" 2>&1 | head -20)
--- plugins/ ---
$(ls -la "$VEL/plugins" 2>&1 | head -20)
--- plugins/connect/ ---
$(ls -la "$VEL/plugins/connect" 2>&1 | head -20)
=== plugins/connect/config.yml ===
$(cat "$VEL/plugins/connect/config.yml" 2>&1)
=== velocity.toml (key lines) ===
$(grep -vE '^\s*#|^\s*$' "$VEL/velocity.toml" 2>&1 | head -25)
=== port 25565 listening? ===
$(ss -ltnp 2>/dev/null | grep -E '25565|25566' || echo 'ss unavailable')
=== local login probe (bypasses the edge) ===
$(python3 "$REPO_DIR/scripts/probe-login.py" 2>&1 | tail -20)
=== backend connections (ss) ===
$(ss -tnp 2>/dev/null | grep -E '25566' || echo none)
=== $VEL/logs/latest.log (tail 30) ===
$(tail -30 "$VEL/logs/latest.log" 2>&1)
=== velocity.log (full) ===
$(cat "$WORK/velocity.log" 2>&1 | tail -60)"
beacon "$(date -u +%H:%M:%S) UTC — SERVER UP (Folia survival via Velocity)
--- velocity.log tail ---
$(tail -25 "$WORK/velocity.log")
--- folia errors ---
$(grep -iE 'error|exception|severe' "$WORK/console.log" | tail -8)"

# Remote console — watch repo file console-command.txt; execute each line
# on the Folia console when the file's sha changes.
CMD_SHA_FILE="$WORK/.cmd_sha"
last_cmd_sha="$(cat "$CMD_SHA_FILE" 2>/dev/null || echo '')"
check_remote_console() {
  local json sha cmds line
  json="$(gh_api "$API/repos/$REPO/contents/console-command.txt" 2>/dev/null)"
  sha="$(echo "$json" | jq -r '.sha // empty')"
  [ -z "$sha" ] || [ "$sha" = "$last_cmd_sha" ] && return 0
  cmds="$(echo "$json" | jq -r '.content' | base64 -d 2>/dev/null)"
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    log "remote-console: $line"
    echo "$line" >&3
    sleep 1
  done <<< "$cmds"
  echo "$sha" > "$CMD_SHA_FILE"
  last_cmd_sha="$sha"
  sleep 3
  beacon "$(date -u +%H:%M:%S) UTC — remote-console executed:
$cmds
--- console tail ---
$(tail -8 "$WORK/console.log")"
}

# Remote handover trigger — creating repo file handover.txt forces a graceful
# handover on the next loop tick. One-shot: the file is consumed when read.
check_handover_trigger() {
  local json sha
  json="$(gh_api "$API/repos/$REPO/contents/handover.txt" 2>/dev/null)"
  sha="$(echo "$json" | jq -r '.sha // empty')"
  [ -z "$sha" ] && return 1
  log "handover trigger file detected — consuming"
  beacon "$(date -u +%H:%M:%S) UTC — handover trigger received, starting graceful handover"
  gh_api -X DELETE "$API/repos/$REPO/contents/handover.txt" \
    -d "{\"message\":\"consume handover trigger\",\"sha\":\"$sha\"}" >/dev/null || true
  return 0
}

# ------------------------------------------------- 5. Serve until handover time
while :; do
  now=$(date +%s)
  if ! kill -0 "${FOLIA_PID:-0}" 2>/dev/null; then
    CRASH_RESTARTS=$((CRASH_RESTARTS + 1))
    if [ "$CRASH_RESTARTS" -gt 3 ]; then log "too many folia crashes, giving up"; exit 4; fi
    log "folia died — restarting (attempt $CRASH_RESTARTS)"
    tail -5 "$WORK/console.log"
    start_folia
  fi
  kill -0 "${VEL_PID:-0}" 2>/dev/null || { log "velocity died — restarting"; start_velocity; }
  [ "$HANDOVER_NOW" = "true" ] && { log "HANDOVER_NOW set"; break; }
  [ "$now" -ge "$HANDOVER_AT" ] && { log "handover window reached"; break; }
  [ "$now" -ge "$HARDRAIL_AT" ] && { log "HARD RAIL — forcing handover"; break; }
  check_remote_console
  # every ~5 min refresh the diag so post-boot tunnel failures stay visible
  now2=$(date +%s)
  if [ $(( now2 - ${LAST_DIAG:-0} )) -ge 300 ]; then
    LAST_DIAG=$now2
    diag "$(date -u +%H:%M:%S) UTC — velocity diag (running)
registered: $(grep -ciE 'registered|tunnel' "$WORK/velocity.log" 2>/dev/null || echo 0) matching lines
=== velocity.log (tail 40) ===
$(tail -40 "$WORK/velocity.log" 2>&1)"
  fi
  check_handover_trigger && { log "remote handover triggered"; break; }
  sleep 20
done

# ------------------------------------------------------------- 6. Handover
handover() {
  log "handover: save-all flush"
  echo "save-all flush" >&3
  sleep 45

  log "handover: snapshotting (server still live)"
  rm -f "$WORK/world-current.tar.gz"
  tar czf "$WORK/world-current.tar.gz" \
    --exclude='logs' --exclude='console.in' --exclude='cache' --exclude='version_history.json' \
    -C "$WORK" server velocity
  log "snapshot size: $(du -sh "$WORK/world-current.tar.gz" | cut -f1)"
  beacon "$(date -u +%H:%M:%S) UTC — snapshot built $(du -sh "$WORK/world-current.tar.gz" | cut -f1), rotating release"

  log "handover: rotating Release assets"
  REL_JSON="$(gh_api "$API/repos/$REPO/releases/tags/world-snapshot")"
  REL_ID="$(echo "$REL_JSON" | jq -r '.id')"
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
  echo "$UP" | jq -r '.state, .size' >/dev/null || log "upload response unclear: $(echo "$UP" | head -c 300)"

  log "handover: stopping stack"
  echo "stop" >&3
  for i in $(seq 1 30); do kill -0 "${FOLIA_PID:-0}" 2>/dev/null || break; sleep 2; done
  kill -9 "${FOLIA_PID:-0}" 2>/dev/null || true
  kill "${VEL_PID:-0}" 2>/dev/null || true

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
