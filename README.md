# mc-247

24/7 public Minecraft practice server on cycling GitHub Actions VMs.

- **Address:** `shadowsinthedark.play.minekube.net` (Minekube Connect plugin, token in repo secrets)
- **Server pack:** operator's custom Leaf 26.2 PvP practice pack (WahidSadikArchive001)
- **World persistence:** GitHub Release `world-snapshot` — asset `world-current.tar.gz` (live) + `world-prev.tar.gz` (rollback)

## How it works

`server.yml` boots a VM (dispatch-triggered), restores the world, serves ~5h10, then
snapshots + uploads while the server is still live, stops, dispatches its successor,
and exits. `watchdog.yml` checks every 15 min that a run is alive and heals the chain
if it breaks. `concurrency: mc-server` guarantees at most one VM ever runs.

## Secrets

| Name | Purpose |
|---|---|
| `GH_PAT` | dispatch successor cycles + Release asset rotation (never rotate — operator order) |
| `CONNECT_TOKEN` | Minekube Connect agent token (binds the endpoint address) |

## Test hooks

- Dispatch `server.yml` with input `handover_now=true` → immediate handover test
- Cancel the running server run → watchdog should heal within ~15 min
