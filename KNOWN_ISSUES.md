# Known Issues

*No open issues.*

## Resolved

### Wake probes failed all LAN services after every sleep/wake

**Resolved:** 2026-06-10

`handleWake()` probed services with the original probe config (host defaults to 127.0.0.1). In LAN mode services bind exclusively to the LAN IP, so every wake marked all three portals FAILED and restarted them — producing waves of probe-timeout debug issues.

**Fix:**
- `handleWake()` now uses `lanAwareDefinition().probe` so the probe targets the host the service is actually bound to
- Probe checks get a 15-second grace window (retry every 3s) instead of a single 2s check 3 seconds after wake

### Stale LAN IP after network change caused EADDRNOTAVAIL crash loops

**Resolved:** 2026-06-10

Moving the machine between networks (e.g., office → home WiFi) while LAN mode was on left `localIP` stale. Wake-triggered restarts passed the dead IP via `--hostname`, and Next.js failed with `EADDRNOTAVAIL`.

**Fix:**
- Extracted `applyNetworkMode()` from `toggleNetworkMode()` — re-detects the current LAN IP, rewrites env files, and restarts LAN services
- `handleWake()` re-detects the IP before probing: if changed → re-apply network mode with the new IP; if no network → fall back to localhost mode
- `scheduleRestart()` re-checks the IP before restarting LAN services and re-applies network mode if it changed

### Stripe restart permanently abandoned when network not ready

**Resolved:** 2026-06-10

Both `handleWake()` (30s wait) and `scheduleRestart()` (15s wait) gave up permanently if the network wasn't ready, leaving Stripe FAILED until a manual restart.

**Fix:** Both paths now schedule a retry with exponential backoff (capped by the existing restartCount < 5 guard) instead of abandoning.

### Watcher tasks leaked on config reload

**Resolved:** 2026-06-10

`loadConfig()` spawned yalc/git watcher tasks without cancelling previous ones, so reconfiguring repos accumulated duplicate 5-second poll loops.

**Fix:** Watcher tasks are stored and cancelled before new ones are spawned.

### DbSetupRunner timeout watchdog lingered and could double-resume

**Resolved:** 2026-06-10

The timeout watchdog task slept for the full step timeout even after the process exited. Worse, if `process.run()` threw, the continuation was resumed without claiming the completion guard — the watchdog would later claim it, call `terminate()` on a never-launched process, and resume the continuation a second time.

**Fix:** Watchdog is cancelled in the termination handler and on launch failure; the launch-failure path now claims the guard before resuming.

### Stripe CLI crash-loops after macOS sleep/wake

**Resolved:** 2026-06-02

Stripe's WebSocket to api.stripe.com dies during macOS sleep. On wake, the CLI enters a "Session expired, reconnecting..." loop that eventually fails with a DNS resolution error and exits code 1. The `handleWake()` method skipped stdout_regex services, so Stripe was never health-checked after wake.

**Fix:**
- `handleWake()` now proactively restarts Stripe after wake with a network readiness check (`waitForNetwork()` polls DNS for up to 30s)
- `scheduleRestart()` checks network availability before restarting Stripe, preventing the circuit breaker from tripping on transient DNS failures
- Added WebSocket degradation early warning: if "Session expired, reconnecting..." messages persist for >2 minutes without successful webhook forwarding, Stripe is automatically restarted

### Travel Portal EADDRINUSE on rapid LAN mode toggle

**Resolved:** 2026-06-02

`toggleNetworkMode()` bypassed `startService()` and called `processRunner.start()` directly, skipping port-cleanup logic. Rapid LAN toggles caused the old process to still hold the port when the new one tried to bind.

**Fix:**
- Refactored `toggleNetworkMode()` to delegate service restart to `startService()`, which kills port occupants and waits for release
- Added reentrancy guard (`isTogglingNetwork`) to prevent concurrent toggle operations
- `lanAwareDefinition()` is now the single source of truth for LAN hostname and env overrides

### restart-cascade/supabase does not trigger db:reset on empty database

**Resolved:** 2026-05-12

**Fix:** 
- `restartCascade()` now checks `databaseHasAppTables()` after Supabase restarts and auto-triggers `db:reset` if the database is empty
- Added `POST /api/db-reset` endpoint to ControlServer for programmatic DB reset
- DB reset output now shows in a live console panel in the Services tab
