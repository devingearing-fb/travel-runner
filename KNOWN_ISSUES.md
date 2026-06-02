# Known Issues

*No open issues.*

## Resolved

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
