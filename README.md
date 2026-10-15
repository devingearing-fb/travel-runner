# travel-runner

macOS menu bar app that orchestrates the Fastbreak travel booking local development environment.

## Quick Start

```bash
./build.sh --run
```

On first launch, a setup wizard guides you through configuring repo paths and verifying prerequisites. Point it at your `fb-travel-monolith` checkout (the pnpm+turbo monorepo with `apps/booking-portal`, `apps/partner-portal`, `packages/travel-data`, and the root `supabase/` and `scripts/`), plus fb-amateur-universal-login, stream-services and travel-load-test. The old sibling repos (travel-booking-portal, fb-amateur-travel-partner-portal, fb-travel-data) are no longer supported; a version 2 config is migrated by finding the monorepo next to the old booking-portal path.

## What It Does

- **One-click startup**: Starts the selected profile in dependency order — `booking` (Supabase, Universal Login, Stripe, booking portal on :3002), `partner` (Supabase, Universal Login, partner portal on :3006), `both` (default), or `full` (adds cache verification, stream-services, QStash, and Sequin; experimental)
- **Health monitoring**: Color-coded status dot in the menu bar (green/amber/red/gray)
- **Stripe secret injection**: Captures `whsec_` from Stripe CLI stdout, writes to the runner block in `apps/booking-portal/.env.local` + serves via HTTP registry
- **Env management**: each app's shared dev values live in the monolith at `apps/<app>/.env` (a teammate's copy, brought in with **Import…** on the Health checks, or `pnpm env:pull` with Doppler access); the runner never holds them. `pnpm env:check` in the monolith says whether a copy is complete. The runner owns a marked block at the end of each app's `.env.local` (`# >>> travel-runner: managed block, ...` to `# <<< travel-runner`) with local Supabase, URL and login overrides
- **Migration detection**: Auto-runs the DB reset (`scripts/db/manifest.json` `reset` profile) on first run, when pending migrations change or a new fb-amateur-backend baseline commit lands, on an empty database, and on a branch switch
- **Shared code**: `packages/travel-data` hot-reloads into both apps — nothing to build or link
- **Console tabs**: Live logs for Stripe, Booking Portal, and Universal Login with Pino JSON formatting
- **Crash recovery**: Auto-restarts failed services with exponential backoff
- **LAN mode**: Toggle to make all services accessible from other devices (mobile testing); rewrites both apps' runner blocks
- **Database mode**: Toggle between local Supabase and hosted dev (needs each profile app's shared `.env`)
- **Sleep/wake**: Re-probes services after macOS wake

## Control API

When running, travel-runner exposes an HTTP API on `http://[::1]:19900` for programmatic control (useful from Claude Code, scripts, or CI):

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/status` | All service statuses, health, LAN mode, profile, DB mode, git branches |
| `GET` | `/api/logs/{serviceId}?lines=N` | Last N log lines (default 50) |
| `POST` | `/api/restart/{serviceId}` | Restart a service |
| `POST` | `/api/restart-cascade/{serviceId}` | Restart a service and its dependents |
| `POST` | `/api/clear-cache-restart/{serviceId}` | Clear `.next` cache + restart (`travel-portal`, `partner-portal`) |
| `POST` | `/api/start-all` | Start the active profile's services |
| `POST` | `/api/stop-all` | Stop all services |
| `POST` | `/api/toggle-lan` | Toggle LAN mode for mobile testing |
| `POST` | `/api/toggle-db-mode` | Toggle local Supabase / hosted dev database |
| `GET` | `/api/profile` | Active profile, its services, available profiles |
| `POST` | `/api/profile/{booking\|partner\|both\|full}` | Set the run profile (400 on unknown) |
| `POST` | `/api/db-reset` | Reset the DB (manifest `reset` profile, selected seed scenario) |
| `POST` | `/api/db-setup` | Run the DB setup pipeline; optional body `{"profile": "full\|reset\|fast"}` |
| `POST` | `/api/db-setup/retry/{stepId}` | Re-run the pipeline from a step |
| `POST` | `/api/db-setup/step/{stepId}` | Run a single step |
| `POST` | `/api/db-setup/cancel` | Cancel a running pipeline |
| `GET` | `/api/db-setup/status` | Pipeline state with per-step progress |
| `GET` | `/api/debug/issues` | List open debug-tracking issues |
| `POST` | `/api/debug/issues` | Capture an issue; body `{"description": "..."}` |
| `POST` | `/api/debug/issues/close/{id}` | Close an issue; optional body `{"resolution": "..."}` |

**Service IDs:** `supabase`, `universal-login`, `stripe`, `travel-portal`,
`partner-portal`, `cache-apply-transport`, `capacity-contention`,
`capacity-block-edit-race`, `capacity-overflow`, `stream-services-install`,
`stream-qstash`, `stream-db-setup`, `stream-services`, `stream-qstash-wire`,
`stream-sequin`, `cache-cdc-rehearsal`, `cache-cutover-audit`

### Examples

```bash
# Check what's running
curl http://localhost:19900/api/status

# Get booking portal logs
curl http://localhost:19900/api/logs/travel-portal?lines=50

# Clear Next.js cache and restart the portal
curl -X POST http://localhost:19900/api/clear-cache-restart/travel-portal

# Run only the partner portal stack on the next start
curl -X POST http://localhost:19900/api/profile/partner

# Toggle LAN mode for phone testing
curl -X POST http://localhost:19900/api/toggle-lan

# Restart universal login
curl -X POST http://localhost:19900/api/restart/universal-login
```

## Cache CDC Rehearsal

Select the `full` profile, choose **Redis cache integration** in DB Tools, and run **Reset & Seed Data** before starting the
full graph. Runner completes the capacity fixtures first, recreates its dedicated local logical
replication slot at the current WAL position, then starts stream-services, QStash, and Sequin.
`cache-cdc-rehearsal` performs a real SQL update and requires all five observations: Postgres WAL,
Sequin delivery, QStash delivery, stream-services handling, and an acknowledged portal apply.

The local evidence artifact is `travel-load-test/.cache-apply/cache-cdc-rehearsal.json`. It is
explicitly local-only and does not satisfy a production gate. Stopping Runner removes the
Runner-owned Sequin containers and volumes; the next run creates a fresh rehearsal topology.

## Configuration

Config lives at `~/.config/travel-runner/services.json` (version 3). The setup wizard creates it on first launch. It holds `paths` (`monorepo`, `universal_login`, `stream_services`, `load_test`) and the `profile`. The service graph is generated in code from the paths on every load, so only custom services you add to `services` are kept as written. Edit manually or use the Settings gear icon in the app.

## Building

Requires Swift 6+ (Xcode or Command Line Tools).

```bash
./build.sh              # Build TravelRunner.app
./build.sh --run        # Build + launch
./build.sh --install    # Build + copy to /Applications
```

## Tech Stack

Swift 6, SwiftUI, [FlyingFox](https://github.com/swhitty/FlyingFox) (embedded HTTP server), SPM
