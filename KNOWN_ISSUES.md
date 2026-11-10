# Known Issues

*No open issues.*

## Resolved

### Two requests for one service started two processes (EADDRINUSE)

**Resolved:** 2026-11-10

Restart, clear-cache-restart, the LAN and database mode switches, the restart after a crash and wake recovery each ran as a separate task. Two of them for one service (two API calls, or a crash restart and a manual restart) each started a process. The second failed with `EADDRINUSE` or "Another next dev server is already running", and the runner recorded a crash.

**Fix:**
- The stop and the start of one service hold a lock for that service (`KeyedLock`). Requests wait in order.
- A second identical request that would also wait is dropped.
- The wait for the health probe holds no lock, so a process that fails while it starts is restarted at once.

### The circuit breaker never tripped

**Resolved:** 2026-11-10

The automatic restart called `restartService()`, which clears the failure history. The count of failures in 60 seconds was 1 each time, so the breaker did not trip and the backoff stayed at 2 seconds. A service that could not start was restarted without end (41 times for Sequin, 32 times for Supabase).

**Fix:**
- The automatic restart keeps the failure history. A manual restart clears it.
- Three failures in 60 seconds stop the restarts. Five restarts in one series stop them too.
- A service that ran for two minutes before it failed starts a new series.

### A stop by the runner, or a kill from outside, was recorded as a crash

**Resolved:** 2026-11-10

`handleTermination()` used the service's phase to tell a deliberate stop from a crash. The wake recovery stopped services without the `stopping` phase. A process that needed SIGKILL ended after the phase had changed. Both gave issues such as "exited with code 143" and "exited with code 9", and a second restart. A `kill` from a script gave the same issue.

**Fix:**
- `ProcessRunner.stop()` marks the launch that it stops. The mark stays with that process, so a late exit cannot fail the process that started after it.
- `stop()` returns when the process tree is gone. It does not wait a fixed two seconds.
- A stop signal from outside (SIGTERM, SIGINT, SIGKILL, SIGHUP, SIGQUIT) restarts the service with a log line. It makes no crash notification and no debug issue.

### A command that the branch does not have was restarted

**Resolved:** 2026-11-10

Exit 126 and 127 mean that the shell could not run the command, for example `./scripts/local-cdc/run-sequin.sh` on a branch without that script. The runner restarted it each time.

**Fix:** There is no automatic restart for exit 126 or 127. The error names the command.

### Supabase showed STOPPED after a cold start

**Resolved:** 2026-11-10

`pnpm db:start` ends with code 0 when the stack is up. The runner read the exit as "Supabase stopped", and the health stayed at STARTING.

**Fix:** A launcher of a reused service that ends with code 0 leaves the service running while its port is bound.

### Port cleanup also killed the clients of the port

**Resolved:** 2026-11-10

`lsof -ti :PORT | xargs kill -9` matches each process with a socket on the port. That includes a browser with a page open, and the Stripe CLI while it forwards to the portal.

**Fix:** Port cleanup kills only the process that listens: `lsof -ti TCP:PORT -sTCP:LISTEN`.

### A stopped container runtime gave a crash loop

**Resolved:** 2026-11-10

With OrbStack or Docker Desktop closed, `supabase start` and the Sequin script failed with "Cannot connect to the Docker daemon" on each restart.

**Fix:** When the output shows that message, the runner opens the runtime and waits for it before the restart. If the runtime does not come up, the restarts stop and the error says to open it.

### Two wake notifications ran two recovery passes

**Resolved:** 2026-11-10

macOS can send two wake notifications a little more than five seconds apart. Each ran a full pass, and both restarted a service that failed its probe.

**Fix:** One pass runs at a time. A notification that comes more than 30 seconds into a pass (the machine slept again) runs one more pass afterward.

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

`loadConfig()` spawned watcher tasks (git, and the since-removed yalc watcher) without cancelling previous ones, so reconfiguring repos accumulated duplicate 5-second poll loops.

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
