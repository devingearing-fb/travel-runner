---
name: travel-runner-api
description: Canonical reference for the travel-runner HTTP control API at localhost:19900. Use when operating services, reading logs, diagnosing failures, or automating dev environment tasks from Claude Code.
trigger: when the user asks to check service status, read logs, restart services, clear cache, toggle LAN mode, or interact with the local dev environment through travel-runner
---

# travel-runner Control API

travel-runner is a macOS menu bar app that supervises the local dev environment. It starts services in dependency order (Supabase -> Stripe/Login/yalc -> Portal), monitors health probes, and exposes an HTTP control API on **http://localhost:19900** for programmatic access.

## Checking availability

Before calling any endpoint, verify travel-runner is up:

```bash
curl -sf http://localhost:19900/api/status > /dev/null && echo "running" || echo "not running"
```

If it's not running, the user needs to launch the TravelRunner.app manually.

## Endpoints

### GET /api/status

Returns the full environment state in one call. Always start here when diagnosing.

```bash
curl -s http://localhost:19900/api/status | python3 -m json.tool
```

**Response shape:**

```json
{
  "health": "HEALTHY",
  "ip": "10.180.0.56",
  "lan": true,
  "services": {
    "supabase":       { "phase": "RUNNING", "pid": "90777" },
    "universal-login": { "phase": "RUNNING", "pid": "94453" },
    "stripe":         { "phase": "RUNNING", "pid": "90777" },
    "travel-portal":  { "phase": "RUNNING", "pid": "62147" },
    "yalc-link":      { "phase": "DONE",    "pid": "90654" }
  }
}
```

**Health values and what they mean:**

| Health | Meaning | Typical action |
|--------|---------|----------------|
| `HEALTHY` | All daemons running, probes passing | None needed |
| `STARTING` | Startup DAG in progress | Wait and poll status again |
| `DEGRADED` | One or more services failed | Check logs for the failed service, restart it |
| `STOPPED` | All services stopped | Call start-all |

**Phase values per service:**

| Phase | Meaning |
|-------|---------|
| `RUNNING` | Daemon alive and health probe passing |
| `STARTING` | Process launched, waiting for probe |
| `FAILED` | Exited non-zero or probe timed out |
| `STOPPED` | Intentionally stopped |
| `STOPPING` | Shutdown in progress |
| `DONE` | Oneshot completed successfully (yalc-link) |
| `PENDING` | Queued, dependencies not yet ready |
| `COMPLETED` | Oneshot finished (alias for DONE) |

### GET /api/logs/{serviceId}?lines=N

Returns the last N log lines (default 50) for a service. Each line includes which output stream it came from and the raw text.

```bash
curl -s "http://localhost:19900/api/logs/travel-portal?lines=100" | python3 -m json.tool
```

**Response shape:**

```json
[
  { "stream": "stdout", "text": "{\"level\":50,\"time\":1778283566225,...,\"msg\":\"CRITICAL: Failed to compute team room totals\"}" },
  { "stream": "stderr", "text": "Module not found: Can't resolve './AdminBadge'" },
  { "stream": "stdout", "text": " GET /book/ZXk-wmFd 200 in 822ms" }
]
```

**Interpreting log entries:**

Log lines from travel-portal and universal-login are a mix of two formats:

1. **Pino JSON logs** (lines starting with `{`): structured application logs. Key fields:
   - `level`: numeric severity. `10`=trace, `20`=debug, `30`=info, `40`=warn, `50`=error, `60`=fatal
   - `msg`: the human-readable message
   - `module`: originating module (e.g. `blocking-facade`, `event-page`, `guest-capacity`)
   - `err`: error object with `type`, `message`, `stack`, and postgres-specific `code`/`hint`/`details`
   - `time`: unix timestamp in milliseconds

2. **Plain text** (everything else): Next.js compile messages (`Compiled in 116ms`), HTTP request lines (`GET /book/... 200 in 822ms`), startup banners, and stderr warnings.

**Filtering for errors programmatically:**

```bash
curl -s "http://localhost:19900/api/logs/travel-portal?lines=200" \
  | python3 -c "
import json, sys
for entry in json.load(sys.stdin):
    text = entry['text']
    if text.startswith('{'):
        try:
            obj = json.loads(text)
            if obj.get('level', 0) >= 50:
                print(f\"[ERR] [{obj.get('module','?')}] {obj.get('msg','')}\")
            elif obj.get('level', 0) >= 40:
                print(f\"[WRN] [{obj.get('module','?')}] {obj.get('msg','')}\")
        except: pass
    elif 'error' in text.lower() or 'Error' in text:
        print(f'[ERR] {text}')
"
```

### POST /api/restart/{serviceId}

Stops the service process, waits briefly, restarts it, and waits for its health probe to pass.

```bash
curl -s -X POST http://localhost:19900/api/restart/travel-portal
```

Response: `{"ok": true}` — returns immediately; restart happens async.

### POST /api/clear-cache-restart/{serviceId}

Deletes the `.next/` cache directory then restarts. Use for the portal services when Turbopack cache becomes stale (module-not-found errors, stale bundles, phantom type errors).

```bash
curl -s -X POST http://localhost:19900/api/clear-cache-restart/travel-portal
```

This is the **nuclear option** for Next.js weirdness. First cold compile after clearing takes 8-12 seconds.

### POST /api/start-all

Starts the full service DAG from scratch: preflight checks, then ground (Supabase), gateway (Stripe, Login, yalc), and portal (travel-portal) phases in order.

```bash
curl -s -X POST http://localhost:19900/api/start-all
```

Only works when health is `STOPPED`. If already running, this is a no-op.

### POST /api/stop-all

Gracefully stops all services in reverse dependency order.

```bash
curl -s -X POST http://localhost:19900/api/stop-all
```

### POST /api/toggle-lan

Toggles LAN network mode. When enabled:
- Detects the local IP via `ipconfig getifaddr en0`
- Patches all `.env.local` files to point Supabase/auth URLs at the LAN IP instead of localhost
- Restarts portal + universal-login bound to `0.0.0.0` so mobile devices on the same network can reach them

```bash
curl -s -X POST http://localhost:19900/api/toggle-lan
```

Check the resulting state with `/api/status` — the `lan` and `ip` fields reflect the current mode.

### POST /api/restart-cascade/{serviceId}

Restarts a service AND all its dependents in topological order. Stops dependents first (reverse order), then restarts from the target forward. Use when a dependency change needs to propagate (e.g., restarting universal-login should also restart travel-portal).

```bash
curl -s -X POST http://localhost:19900/api/restart-cascade/universal-login
```

Response: `{"ok": true}` — cascade runs async.

### POST /api/db-reset

Triggers a database reset using the legacy monolithic approach (`npm run db:setup --reset-only`). Prefer `/api/db-setup` for granular control.

```bash
curl -s -X POST http://localhost:19900/api/db-reset
```

### POST /api/db-setup

Runs the granular database setup pipeline. Accepts an optional JSON body with a profile name.

```bash
# Default "reset" profile (migrations + seed + hotels)
curl -s -X POST http://localhost:19900/api/db-setup

# Full setup including remote contract fetch
curl -s -X POST http://localhost:19900/api/db-setup \
  -H "Content-Type: application/json" \
  -d '{"profile": "full"}'

# Fast: just migrations + seed, skip hotels
curl -s -X POST http://localhost:19900/api/db-setup \
  -H "Content-Type: application/json" \
  -d '{"profile": "fast"}'
```

**Profiles:** `full` (all 7 steps), `reset` (skip remote contracts), `fast` (skip hotels + contracts)

### POST /api/db-setup/retry/{stepId}

Re-run the database setup pipeline from a specific step. Steps before the retry point keep their previous status.

```bash
curl -s -X POST http://localhost:19900/api/db-setup/retry/load-hotels
```

**Step IDs:** `check-prerequisites`, `start-supabase`, `sync-migrations`, `reset-database`, `load-hotels`, `copy-event-data`, `verify-data`

### POST /api/db-setup/cancel

Cancel a running database setup pipeline.

```bash
curl -s -X POST http://localhost:19900/api/db-setup/cancel
```

### GET /api/db-setup/status

Returns the current state of the database setup pipeline with per-step details.

```bash
curl -s http://localhost:19900/api/db-setup/status | python3 -m json.tool
```

**Response shape:**
```json
{
  "running": true,
  "steps": [
    { "id": "check-prerequisites", "name": "Prerequisites", "status": "PASSED", "elapsed_seconds": 2, "optional": false },
    { "id": "start-supabase", "name": "Start Supabase", "status": "PASSED", "elapsed_seconds": 1, "optional": false },
    { "id": "sync-migrations", "name": "Sync Migrations", "status": "PASSED", "elapsed_seconds": 0, "optional": false },
    { "id": "reset-database", "name": "Apply Migrations", "status": "RUNNING", "progress": 0.65, "progress_label": "Migration 110/167", "optional": false },
    { "id": "load-hotels", "name": "Load Hotels", "status": "PENDING", "optional": true },
    { "id": "copy-event-data", "name": "Event Contracts", "status": "PENDING", "optional": true },
    { "id": "verify-data", "name": "Verify Data", "status": "PENDING", "optional": false }
  ]
}
```

**Step status values:** `PENDING`, `RUNNING`, `CHECKING` (health check), `PASSED`, `FAILED`, `SKIPPED`, `TIMED_OUT`

Failed steps include `error` and `recovery` fields with diagnostic info.

### POST /api/db-setup/step/{stepId}

Run a single database setup step independently. Does NOT run the full pipeline — just executes the one step. Useful for re-running just hotel load or just verification.

```bash
# Re-run just the hotel data load
curl -s -X POST http://localhost:19900/api/db-setup/step/load-hotels

# Re-run just verification
curl -s -X POST http://localhost:19900/api/db-setup/step/verify-data
```

**Step IDs:** `check-prerequisites`, `start-supabase`, `sync-migrations`, `reset-database`, `load-hotels`, `copy-event-data`, `verify-data`

### GET /api/debug/issues

List open debug-tracking issues. Returns `[]` if debug-tracking is not enabled.

```bash
curl -s http://localhost:19900/api/debug/issues | python3 -m json.tool
```

**Response shape:**
```json
[
  {
    "id": "20260513T143022_service-crash-travel-portal",
    "summary": "Travel Portal exited with code 1",
    "severity": "error",
    "category": "service_crash",
    "created_at": "2026-05-13T14:30:22Z"
  }
]
```

### POST /api/debug/issues

Manually capture a debug issue. The system auto-captures most errors, but use this for issues the auto-capture missed.

```bash
curl -s -X POST http://localhost:19900/api/debug/issues \
  -H "Content-Type: application/json" \
  -d '{"description": "Portal showing stale data after branch switch"}'
```

### POST /api/debug/issues/close/{id}

Close a debug issue after fixing it. Moves from `open/` to `closed/`.

```bash
curl -s -X POST "http://localhost:19900/api/debug/issues/close/20260513T143022_service-crash-travel-portal" \
  -H "Content-Type: application/json" \
  -d '{"resolution": "Fixed missing RLS grant in migration"}'
```

## Service IDs

| ID | Service | Type | Port |
|----|---------|------|------|
| `supabase` | Local Supabase (Docker) | daemon, reuse-if-running | 54321 |
| `universal-login` | Auth gateway | daemon | 3000 |
| `stripe` | Stripe CLI webhook listener | daemon | none (captures whsec_ secret) |
| `travel-portal` | Booking portal (Next.js) | daemon | 3002 |
| `yalc-link` | yalc link for fb-travel-data | oneshot | none |

## Diagnostic workflows

### "The portal is showing errors"

1. `GET /api/status` — confirm travel-portal phase is RUNNING
2. `GET /api/logs/travel-portal?lines=200` — scan for level 50 (error) entries
3. Look at `module` and `err.code` fields to identify the source
4. If it's a postgres permission error (`code: "42501"`), the issue is RLS/grants — not a service problem
5. If it's module-not-found, `POST /api/clear-cache-restart/travel-portal`

### "A service won't start or keeps crashing"

1. `GET /api/status` — identify which service has phase FAILED
2. `GET /api/logs/{serviceId}?lines=100` — read the last output before crash
3. `POST /api/restart/{serviceId}` — attempt restart
4. If it fails again, check for port conflicts (`lsof -ti :PORT`)

### "Need to test on mobile"

1. `POST /api/toggle-lan` — enable LAN mode
2. `GET /api/status` — read the `ip` field
3. Navigate to `http://{ip}:3002` on the mobile device
4. `POST /api/toggle-lan` again to disable when done

### "Diagnosing with debug-tracking"

1. `GET /api/debug/issues` — check for auto-captured issues first
2. If an issue exists, read it for pre-captured context (logs, state, git branches)
3. After fixing the root cause, close it: `POST /api/debug/issues/close/{id}`
4. Issues persist at `~/Desktop/debug-tracking/open/` if the API is unavailable

### "Database won't reset"

1. `POST /api/db-setup` — run the granular pipeline (shows per-step progress)
2. If a step fails, check the UI for the specific error and recovery guidance
3. Retry from the failed step: `POST /api/db-setup/retry/{stepId}`
4. For a clean slate: `POST /api/db-setup` with `{"profile": "full"}`
