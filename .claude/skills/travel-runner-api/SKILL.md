---
name: travel-runner-api
description: Canonical reference for the travel-runner HTTP control API at localhost:19900. Use when operating services, reading logs, diagnosing failures, or automating dev environment tasks from Claude Code.
trigger: when the user asks to check service status, read logs, restart services, clear cache, toggle LAN mode, or interact with the local dev environment through travel-runner
---

# travel-runner Control API

travel-runner is a macOS menu bar app that supervises the local dev environment. It runs the `fb-travel-monolith` pnpm+turbo monorepo (apps/booking-portal on :3002, apps/partner-portal on :3006, packages/travel-data, root `supabase/` and `scripts/`), starts the services of the selected profile in dependency order (Supabase -> Login/Stripe -> portals), monitors health probes, and exposes an HTTP control API on **http://localhost:19900** for programmatic access.

**Two apps.** Travel Runner (fb-travel-monolith) answers on port 19900. Travel Runner Hackathon (fb-travel-monolith-hackathon) answers on port **19901** with the same API, and has three more service IDs: `amateur-agent` (the eve agent, port 2000), `platform-core` (platform core, port 3007: the port of the script `dev:dev` in `apps/platform-core/package.json` of the fork) and `event-directory` (the event listing site, port 3004). Each of the three is `SKIPPED` when the Mac does not have what it needs; its log says why. `GET /api/status` has the field `app` (`standard` or `hackathon`). Only one of the two apps can run a stack at a time.

## Checking availability

Before calling any endpoint, verify travel-runner is up:

```bash
curl -sf http://localhost:19900/api/status > /dev/null && echo "running" || echo "not running"
```

If it's not running, the user needs to launch the TravelRunner.app manually.

## Answers

Every route answers JSON. A route never says ok when nothing ran:

| Status | When | Body |
|---|---|---|
| 200 | A read, or a change that is done before the answer (`/api/profile/{name}`, closing an issue) | the data, or `{"ok":true}` |
| 202 | The action runs now, or after the stack operation before it | `{"accepted":true,"ok":true}`; Start All during a stop adds `"state":"queued_after_stop"` |
| 400 | A parameter or a body the route cannot read (`?lines=many`, a body that is not a JSON object), or an unknown profile | `{"error":"…","ok":false}`; an unknown profile adds `known_profiles` |
| 404 | No such service, step, issue, log or route | `{"error":"unknown service 'x'","known":[…],"ok":false}`; a step has `known_steps` |
| 409 | The action cannot run now: the stack is stopped or stopping, the same action is queued, a start runs, a DB setup runs (`"a DB setup run is in progress (step: <name>)"`) or already waits, a database switch is refused, issue capture is off, the runner is quitting, or the runner is too old for the checkout (`runner_too_old`) | `{"error":"…","ok":false}` |
| 422 | A reset with no valid seed scenario | `{"error":"…","ok":false}` |

Read `error` and act on it: a 409 for a stopped stack says `POST /api/start-all first`.

## Endpoints

### GET /api/status

Returns the full environment state in one call. Always start here when diagnosing.

```bash
curl -s http://localhost:19900/api/status | python3 -m json.tool
```

**Response shape:**

```json
{
  "branches": { "travel-portal": "dev", "partner-portal": "dev" },
  "build": "20261116120000",
  "build_kind": "release",
  "commit": "a1b2c3d",
  "db_mode": "local",
  "gitBehind": { "travel-portal": 0 },
  "health": "HEALTHY",
  "ip": "10.180.0.56",
  "lan": true,
  "npmStale": [],
  "profile": "both",
  "services": {
    "supabase":        { "phase": "RUNNING", "pid": "90777" },
    "universal-login": { "phase": "RUNNING", "pid": "94453" },
    "stripe":          { "phase": "RUNNING", "pid": "90778" },
    "travel-portal":   { "phase": "RUNNING", "pid": "62147" },
    "partner-portal":  { "phase": "RUNNING", "pid": "62190" },
    "stream-services": { "phase": "SKIPPED", "pid": "nil" }
  },
  "version": "0.13.5"
}
```

- `version`, `build`, `commit`, `build_kind`: which Travel Runner answers. `build_kind` is `release` (from `release.sh`) or `dev` (built from source with `build.sh`; its `version` comes from `git describe`). A value that the build does not know is `""`.

- `profile`: the active run profile (`booking`, `partner`, `both`, `full`) — see `/api/profile`
- `db_mode`: `local` (local Supabase) or `remote` (hosted dev, from the apps' shared `.env` files) — see `/api/toggle-db-mode`
- `ip` is `"none"` when LAN mode is off; `pid` is `"nil"` when the service has no process
- `branches` / `gitBehind`: current git branch and commits-behind count per service repo; `npmStale`: service IDs whose dependencies need a reinstall

**Health values and what they mean:**

| Health | Meaning | Typical action |
|--------|---------|----------------|
| `HEALTHY` | All daemons running, probes passing | None needed |
| `STARTING` | Startup DAG in progress | Wait and poll status again |
| `DEGRADED` | One or more services failed | Check logs for the failed service, restart it |
| `STOPPED` | All services stopped | Call start-all |

`health_reason` is there when the health has a reason: the failed service and its headline, the services that are off ("OK · Stripe webhooks off"), or a refused start ("Not started — 2 checks failed").

### GET /api/preflight

Runs the start checks that change nothing (the fast setup checks of Health, the ports, the folders) and gives each result: `{"configured":true,"checks":[{"id":"…","name":"…","status":"passed|warning|failed|pending","detail":"…","fix":"…"}]}`. `fix` is there only for a failed check that has one. It starts nothing, so it is safe to call on a stopped stack.

### GET /api/health

Only the health and its reason: `{"health":"DEGRADED","health_reason":"Booking Portal failed: …"}`.

### GET /api/services

Each service in start order: `id`, `name`, `phase`, `pid`, `in_profile`, and when there is one, `reason` (why it failed), `skip_reason`, `likely_cause`, `last_probe` and `action` (the fix button).

### GET /api/diagnostics

The diagnostics snapshot that an issue saves (`diagnostics.json`): app version and build, macOS, the tools, profile, DB mode, preflight results, the DB pipeline, pending migrations, repo paths with `~`, and each service. Secrets are masked. It takes a few seconds: it reads the tools.

### GET /api/events

The events of `events.jsonl` that make no issue (Stripe skips, outside kills, breaker trips, DB resets), oldest first. `[]` while issue capture is off.

**Phase values per service:**

| Phase | Meaning |
|-------|---------|
| `RUNNING` | Daemon alive and health probe passing |
| `STARTING` | Process launched, waiting for probe |
| `FAILED` | Exited non-zero or probe timed out |
| `STOPPED` | Intentionally stopped |
| `STOPPING` | Shutdown in progress |
| `DONE` | Oneshot completed successfully (e.g. stream-db-setup, cache-apply-transport) |
| `PENDING` | Queued, dependencies not yet ready |
| `SKIPPED` | Not in the active profile (or skipped) — not started |

### GET /api/logs

The ids that `/api/logs/{id}` reads: `{"ids":["supabase",…,"db-setup-load-hotels","runner"]}`. A DB step's log is `db-setup-<stepId>`.

### GET /api/logs/{id}?lines=N

Returns the last N log lines (default 50) of a service or a DB step (`db-setup-<stepId>`), with secrets masked. Each line includes which output stream it came from and the text. `lines` must be a positive number (else 400); an id with no log is a 404.

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

Log lines from travel-portal, partner-portal and universal-login are a mix of two formats:

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

Response: 202 `{"accepted":true,"ok":true}` — the restart runs after the answer. 404 for an unknown service (with `known`), 409 when the stack is stopped or stopping, or the same restart already waits.

For `supabase` the restart only starts what is down; the containers keep running. `POST /api/restart/supabase?stack=1` stops and starts the Supabase containers (the data stays; about a minute with the database down under the running portals). The panel asks before it does this; the API does not, so use it only when the stack is broken.

### POST /api/clear-cache-restart/{serviceId}

Deletes the `.next/` cache directory in the service's directory then restarts. Use for the portal services (`travel-portal`, `partner-portal`) when Turbopack cache becomes stale (module-not-found errors, stale bundles, phantom type errors).

```bash
curl -s -X POST http://localhost:19900/api/clear-cache-restart/travel-portal
```

This is the **nuclear option** for Next.js weirdness. First cold compile after clearing takes 8-12 seconds. Answers like `/api/restart`.

### POST /api/start-all

Starts the active profile's service DAG from scratch: preflight checks, then ground (Supabase), gateway (Login, Stripe), and portal (travel-portal, partner-portal) phases in order. Under the `full` profile the stream and verification phases follow. Services outside the profile stay `SKIPPED`.

```bash
curl -s -X POST http://localhost:19900/api/start-all
```

A start that is already running answers 409. A start during Stop All waits for the stop and answers 202 with `"state":"queued_after_stop"`. On a stack that runs, Start All restarts everything.

### POST /api/stop-all

Gracefully stops all services in reverse dependency order.

```bash
curl -s -X POST http://localhost:19900/api/stop-all
```

Response: 202 `{"accepted":true,"ok":true}`; the stop runs after the answer. A Start All or a DB setup that waits behind it is dropped. Poll `/api/status` until `health` is `STOPPED`.

### POST /api/toggle-lan

Toggles LAN network mode. When enabled:
- Detects the local IP via `ipconfig getifaddr en0`
- Rewrites the runner-managed block in both apps' `.env.local` (and universal-login's `.env.local`) to point Supabase/auth/app URLs at the LAN IP instead of localhost
- Restarts travel-portal, universal-login (and partner-portal when it is in the profile) bound to `0.0.0.0` so mobile devices on the same network can reach them

```bash
curl -s -X POST http://localhost:19900/api/toggle-lan
```

Check the resulting state with `/api/status` — the `lan` and `ip` fields reflect the current mode.

### POST /api/restart-cascade/{serviceId}

Restarts a service AND all its dependents in topological order. Stops dependents first (reverse order), then restarts from the target forward. Use when a dependency change needs to propagate (e.g., restarting universal-login should also restart travel-portal).

```bash
curl -s -X POST http://localhost:19900/api/restart-cascade/universal-login
```

Response: 202 — the restart runs after the answer; refusals as for `/api/restart`. The panel calls this "Restart with dependents".

### GET /api/profile

Returns the active run profile, the service IDs it starts, and the available profiles.

```bash
curl -s http://localhost:19900/api/profile | python3 -m json.tool
```

**Response shape:**

```json
{
  "available": ["booking", "partner", "both", "full"],
  "profile": "both",
  "services": ["partner-portal", "stripe", "supabase", "travel-portal", "universal-login"]
}
```

**Profiles:**

| Profile | Services |
|---------|----------|
| `booking` | supabase, universal-login, stripe, travel-portal |
| `partner` | supabase, universal-login, partner-portal |
| `both` (default) | union of booking + partner |
| `full` (experimental) | every service, incl. `stream-*`, `cache-*`, `capacity-*` |

Custom services from `services.json` join a profile when all their dependencies are in it.

### POST /api/profile/{booking|partner|both|full}

Sets the run profile (saved to `~/.config/travel-runner/services.json`). It does not start or stop anything by itself: the next `start-all` brings up the new profile's services, and services outside it show phase `SKIPPED`. While the stack runs, the app says "Profile saved — applies on the next start." and offers **Apply now**, which stops the services that left the profile and starts the ones that joined it.

```bash
curl -s -X POST http://localhost:19900/api/profile/partner
```

Response: 200 `{"ok":true}`; an unknown profile name returns 400 with `known_profiles`.

### POST /api/toggle-db-mode

Toggles between local Supabase (localhost:54321) and the hosted dev database. Rewrites the runner-managed block in each app's `.env.local` (and universal-login's env), then restarts travel-portal, universal-login (and partner-portal when it is in the profile). Allowed when the stack is stopped, healthy or degraded; during a start, a stop or another switch it answers 409 with the reason. The API does not ask before a switch to the shared dev data.

```bash
curl -s -X POST http://localhost:19900/api/toggle-db-mode
```

Switching to remote needs the hosted dev values in the shared `.env` of each profile app (`apps/booking-portal/.env`, and `apps/partner-portal/.env` when partner runs); without them the switch is refused. `pnpm env:check` at the monorepo root shows what is missing. Check the result in the `db_mode` field of `/api/status`.

**Env layout:** each app's shared dev values are in the monolith at `apps/<app>/.env`: a teammate's copy (Health → **Import…**) or `pnpm env:pull` with Doppler access. The runner never stores them. The runner owns a marked block at the end of each app's `.env.local`, between `# >>> travel-runner: managed block, rewritten on start and on mode changes` and `# <<< travel-runner`. Local mode overrides Supabase (including `AMATEUR_SUPABASE_*`), app URLs and the login URL; remote mode leaves Supabase to the shared `.env`.

### POST /api/db-reset

Resets the database by running the manifest `reset` profile (see `/api/db-setup`) with the selected seed scenario. Same as `POST /api/db-setup` with no body.

```bash
curl -s -X POST http://localhost:19900/api/db-reset
```

The runner sets up the database by itself only when it is empty (with the `reset` profile). Missing or extra migrations show a banner with **Apply migrations** (the `migrate` profile, never resets) and **Reset and reseed…** (asks first). A branch switch does not reset. The Settings option "Reset the database when migrations change" (off by default) turns on a reset when migrations change, and even then it never resets a database another checkout built.

### POST /api/db-setup

Runs the granular database setup pipeline defined by `scripts/db/manifest.json` (version 4) at the monorepo root. Accepts an optional JSON body with a profile name (default `reset`). The DB container is `supabase_db_fb-travel`.

```bash
# Default "reset" profile (migrations + seed + hotels + verify)
curl -s -X POST http://localhost:19900/api/db-setup

# Full setup including event contract copy
curl -s -X POST http://localhost:19900/api/db-setup \
  -H "Content-Type: application/json" \
  -d '{"profile": "full"}'

# Fast: just migrations + seed + verify, skip hotels
curl -s -X POST http://localhost:19900/api/db-setup \
  -H "Content-Type: application/json" \
  -d '{"profile": "fast"}'

# Migrate: apply the missing migrations to the data there is, never resets
curl -s -X POST http://localhost:19900/api/db-setup \
  -H "Content-Type: application/json" \
  -d '{"profile": "migrate"}'
```

**Profiles:** `full` (all steps), `reset` (skip event contracts), `fast` (skip hotels + contracts), `migrate` (apply migrations only, never resets). A profile the branch's manifest does not define runs nothing and answers 400 with `known_profiles`.

No body, or `{}`, runs `reset`. A body that is not a JSON object, or a `profile` that is not a string, answers 400 and runs nothing. A DB setup that already runs answers 409 (`"a DB setup run is in progress (step: <name>)"`); no valid seed scenario answers 422. Accepted runs answer 202; follow them with `GET /api/db-setup/status`. During a start or a stop the setup waits for it and still answers 202; a second setup while one waits answers 409 (`"A database setup already waits for the running start or step."`), so two resets never queue.

**After a reset** a step can ask for services to restart (`##db:restart:` in `scripts/db/README.md`): when Sequin's replication slot is gone, the runner restarts `stream-db-setup`, then `stream-sequin`, if they run, once the run has passed.

### POST /api/db-setup/retry/{stepId}

Re-run the database setup pipeline from a specific step. Steps before the retry point keep their previous status. An id that neither the shown pipeline nor the `reset` profile has answers 404 with `known_steps`.

```bash
curl -s -X POST http://localhost:19900/api/db-setup/retry/load-hotels
```

**Step IDs:** `check-prerequisites`, `start-supabase`, `reset-database`, `load-hotels`, `copy-event-data` (optional), `verify-data`

### POST /api/db-setup/cancel

Cancel a running database setup pipeline. The step and its child processes are stopped (SIGTERM, then SIGKILL); `running` stays true until they are gone. With nothing running it answers 409.

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
  "profile": "reset",
  "selectedSeedScenario": { "id": "...", "name": "...", "description": "...", "fileSummary": "..." },
  "activeSeedScenario": { "id": "...", "name": "...", "description": "...", "fileSummary": "..." },
  "steps": [
    { "id": "check-prerequisites", "name": "Prerequisites", "status": "PASSED", "elapsed_seconds": 2, "optional": false },
    { "id": "start-supabase", "name": "Start Supabase", "status": "PASSED", "elapsed_seconds": 1, "optional": false },
    { "id": "reset-database", "name": "Reset & Seed Data", "status": "RUNNING", "progress": 0.65, "progress_label": "Migration 110/167", "optional": false },
    { "id": "load-hotels", "name": "Load Hotels", "status": "PENDING", "optional": false },
    { "id": "copy-event-data", "name": "Event Contracts", "status": "PENDING", "optional": true },
    { "id": "verify-data", "name": "Verify Data", "status": "PENDING", "optional": false }
  ]
}
```

**Step status values:** `PENDING`, `RUNNING`, `CHECKING` (health check), `PASSED`, `FAILED`, `SKIPPED`, `TIMED_OUT` (no output for 180 s, or past the step's hard cap), `CANCELLED` (Cancel, Stop All or a quit; not a failure, no `error`)

Failed steps include `error` and `recovery` fields with diagnostic info; steps may also carry `health_result`. `profile` and the seed scenarios are `null` when no pipeline has run.

### POST /api/db-setup/step/{stepId}

Run a single database setup step independently. Does NOT run the full pipeline — just executes the one step. Useful for re-running just hotel load or just verification. The step can be from any profile of the manifest, also one the last run did not have (`load-hotels` after a `fast` run). An unknown id answers 404 with `known_steps`.

```bash
# Re-run just the hotel data load
curl -s -X POST http://localhost:19900/api/db-setup/step/load-hotels

# Re-run just verification
curl -s -X POST http://localhost:19900/api/db-setup/step/verify-data
```

**Step IDs:** `check-prerequisites`, `start-supabase`, `reset-database`, `load-hotels`, `copy-event-data` (optional), `verify-data`

### GET /api/debug/status

Whether issue capture is on, the open count and the issue folder:

```json
{ "enabled": true, "folder": "~/Library/Application Support/Travel Runner/issues", "open_issues": 2 }
```

### GET /api/debug/issues

List open debug-tracking issues (no query parameters; closed issues are only on disk). Returns `[]` if issue capture is off (it is on by default; Settings has the switch); `GET /api/debug/status` tells that apart from no open issues.

```bash
curl -s http://localhost:19900/api/debug/issues | python3 -m json.tool
```

**Response shape:**
```json
[
  {
    "id": "20260513T143022_service-crash-travel-portal",
    "summary": "service_crash [travel-portal]: Travel Portal exited with code 1",
    "severity": "error",
    "status": "open",
    "category": "runtime",
    "service_id": "travel-portal",
    "created_at": "2026-05-13T14:30:22.000Z",
    "recurrence_count": "0"
  }
]
```

When the service's output shows the cause, `summary` ends with ` — <likely cause>` (for example `… exited with code 1 — Error: listen EADDRINUSE: address already in use :::3002`).

### POST /api/debug/issues

Manually capture a debug issue. The system auto-captures most errors, but use this for issues the auto-capture missed. The only body field is `description`. Response: 202 (capture is async; the ID is not returned); 409 `issue capture is off` when capture is off; 400 for a body that is not a JSON object.

```bash
curl -s -X POST http://localhost:19900/api/debug/issues \
  -H "Content-Type: application/json" \
  -d '{"description": "Portal showing stale data after branch switch"}'
```

### POST /api/debug/issues/close/{id}

Close a debug issue after fixing it. Moves from `open/` to `closed/`. Body is optional (`resolution` defaults to `"Closed via API"`). Response: 200 `{"ok":true}`, 404 `{"error":"issue not found","ok":false}`, or 409 when capture is off.

```bash
curl -s -X POST "http://localhost:19900/api/debug/issues/close/20260513T143022_service-crash-travel-portal" \
  -H "Content-Type: application/json" \
  -d '{"resolution": "Fixed missing RLS grant in migration"}'
```

## Service IDs

The service graph is generated in code (`ServiceCatalog`) from the `paths` in `~/.config/travel-runner/services.json` (version 3: `monorepo`, `universal_login`, `stream_services`, `load_test`, plus `profile`) on every load. Custom services in the file are kept.

| ID | Service | Type | Port | Profiles |
|----|---------|------|------|----------|
| `supabase` | Local Supabase (Docker), `pnpm db:start` at the monorepo root | daemon, reuse-if-running | 54321 (API), 54322 (DB probe) | all |
| `universal-login` | Auth gateway (fb-amateur-universal-login) | daemon | 3000 | all |
| `stripe` | Stripe CLI webhook listener | daemon | none (captures whsec_ secret) | booking, both, full |
| `travel-portal` | Booking portal, `pnpm dev` in `apps/booking-portal` | daemon | 3002 (probe `/api/health`) | booking, both, full |
| `partner-portal` | Partner portal, `pnpm dev` in `apps/partner-portal` | daemon | 3006 (probe `http://127.0.0.1:3006/api/health`) | partner, both, full |
| `stream-services-install` | npm install in stream-services | oneshot | none | full |
| `stream-qstash` | Local QStash | daemon | 8080 | full |
| `stream-db-setup` | Stream CDC database setup | oneshot | none | full |
| `stream-services` | Stream services | daemon | 3003 | full |
| `stream-qstash-wire` | QStash worker wiring | oneshot | none | full |
| `stream-sequin` | Local Sequin cache CDC | daemon | 7376 | full |
| `cache-apply-transport` | Cache apply transport check (travel-load-test) | oneshot | none | full |
| `cache-cdc-rehearsal` | Cache CDC rehearsal (travel-load-test) | oneshot | none | full |
| `cache-cutover-audit` | Cache cutover audit (travel-load-test) | oneshot | none | full |
| `capacity-contention` | Capacity contention E2E (travel-load-test) | oneshot | none | full |
| `capacity-block-edit-race` | Capacity block edit race (travel-load-test) | oneshot | none | full |
| `capacity-overflow` | Capacity overflow E2E (travel-load-test) | oneshot | none | full |

Shared code in `packages/travel-data` hot-reloads into both apps; there is nothing to build or link.

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
3. `POST /api/restart/{serviceId}` — attempt restart (202 means it was accepted; read `/api/status` for the result). For `supabase` this starts what is down; `?stack=1` stops and starts the containers too
4. If it fails again, check for port conflicts (`lsof -ti TCP:PORT -sTCP:LISTEN`; plain `lsof -ti :PORT` also lists the clients of the port, such as a browser — do not kill those)
5. A service whose reason says "failed 3 times in a minute" or "did not come back after 5 restarts" stopped its automatic restarts. Fix the cause in its log, then `POST /api/restart/{serviceId}`. "Something else keeps stopping …" means another process kills it (SIGKILL often means low memory). "… is not running — waiting for it" means the container runtime is down; the service starts by itself when it is back (the wait lasts 10 minutes)

Requests for one service run one at a time. A restart that arrives while another runs waits for it; a second identical request that would also wait is dropped.

### "Partner portal is showing errors"

Same as above with `partner-portal` (port 3006). If it is `SKIPPED`, it is not in the active profile: `POST /api/profile/both` (or `partner`), then `POST /api/stop-all` and `POST /api/start-all`.

### "Need to test on mobile"

1. `POST /api/toggle-lan` — enable LAN mode
2. `GET /api/status` — read the `ip` field
3. Navigate to `http://{ip}:3002` on the mobile device
4. `POST /api/toggle-lan` again to disable when done

### "Diagnosing with debug-tracking"

1. `GET /api/debug/issues` — check for auto-captured issues first (`GET /api/debug/status` says whether capture is on)
2. If an issue exists, read it for pre-captured context (logs, state, git branches)
3. After fixing the root cause, close it: `POST /api/debug/issues/close/{id}`
4. Issues persist on disk if the API is unavailable: `~/Library/Application Support/Travel Runner/issues/open/`, or `~/Desktop/debug-tracking/open/` on a Mac that has a config there

### "Database won't reset"

1. `POST /api/db-setup` — run the granular pipeline (shows per-step progress; `GET /api/db-setup/status` to monitor; a 409 or 422 says why it did not run)
2. If a step fails, read `error` and `recovery` in the status, and its log at `GET /api/logs/db-setup-<stepId>`
3. Retry from the failed step: `POST /api/db-setup/retry/{stepId}`
4. For a clean slate: `POST /api/db-setup` with `{"profile": "full"}`
