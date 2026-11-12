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
- **Env management**: each app's shared dev values live in the monolith at `apps/<app>/.env` (a teammate's copy, brought in with **Import…** on the Environment Check step (Settings → Reconfigure Repos…), or `pnpm env:pull` with Doppler access); the runner never holds them. `pnpm env:check` in the monolith says whether a copy is complete. The runner owns a marked block at the end of each app's `.env.local` (`# >>> travel-runner: managed block, ...` to `# <<< travel-runner`) with local Supabase, URL and login overrides
- **Migration detection**: Auto-runs the DB reset (`scripts/db/manifest.json` `reset` profile) on first run, when pending migrations change or a new fb-amateur-backend baseline commit lands, on an empty database, and on a branch switch
- **Shared code**: `packages/travel-data` hot-reloads into both apps — nothing to build or link
- **Console tabs**: Live logs for Stripe, Booking Portal, and Universal Login with Pino JSON formatting
- **Crash recovery**: Auto-restarts failed services with exponential backoff, and stops after 3 failures in a minute (circuit breaker). A service that someone stops from outside (`kill`) comes back without a crash report
- **LAN mode**: Toggle to make all services accessible from other devices (mobile testing); rewrites both apps' runner blocks
- **Database mode**: Toggle between local Supabase and hosted dev (needs each profile app's shared `.env`)
- **Sleep/wake**: Re-probes services after macOS wake, one pass per wake
- **Rooms tab**: For one event and hotel, shows how many rooms of each room type are booked, held and free on each night, and who holds them. A switch selects the local stack or dev. The tab is read-only. It shows the page of the monolith's holds viewer (`scripts/holds-viewer`): the copy in your checkout, or the copy of `origin/dev` when your branch does not have it. Dev needs only the shared `apps/<app>/.env`, not Doppler. The viewer runs while the tab is open and stops 10 minutes after it closes. `defaults write ai.fastbreak.travel-runner holdsViewerPath <folder>` makes the tab use a copy from another folder; `defaults delete ai.fastbreak.travel-runner holdsViewerPath` removes that

## Travel Runner Hackathon

The same source makes a second app, Travel Runner Hackathon, for the hackathon fork (`SnapBuild-2026/fb-travel-monolith-hackathon`). `FLAVOR=hackathon ./build.sh` builds it; `FLAVOR=hackathon ./release.sh <version>` releases it (tag `hackathon-v<version>`, never the latest release; its update feed is the fixed release `hackathon-appcast`).

- **Own state**: bundle ID `ai.fastbreak.travel-runner-hackathon`, config in `~/.config/travel-runner-hackathon/`, control API on port **19901**, tickets in `~/Desktop/debug-tracking-hackathon`, hotkey Control-Shift-H. A person can have the two apps
- **One stack at a time**: the two apps use the same service ports. An app does not start a stack while the other app runs one
- **Setup** takes only a checkout that has `apps/amateur-agent`, so a folder with the two repos gives each app its own repo
- **Amateur Agent** (`amateur-agent`, port 2000): the runner starts `pnpm exec eve dev --no-ui` in `apps/amateur-agent`. An `eve dev` (`pnpm dev`) in a terminal then opens the REPL on that server. eve needs Node 24 or later: when the default Node is older, the runner uses one from nvm, fnm, mise, Volta, asdf or Homebrew (`node@24`) for the agent only. With no such Node, or without the packages, the agent is skipped and the portals start
- **Agent env**: the runner writes no file for the agent. For an `AMATEUR_SUPABASE_*` key that `apps/amateur-agent/.env.local` does not set, the runner gives the agent the value of `apps/booking-portal/.env`. Do not paste the Doppler line of `AMATEUR_SUPABASE_SIGNING_KEY` into the agent's `.env.local`: eve cannot read its escaped quotes. Put `AI_GATEWAY_API_KEY` in the agent's `.env.local`, or use `/login` in the REPL
- **Model credential of the agent**: when no file gives the agent `AI_GATEWAY_API_KEY` or `VERCEL_OIDC_TOKEN`, the runner gives it a token of the event directory's Vercel project (`VERCEL_OIDC_TOKEN`, as process env). That project then pays for the model calls of the agent (AI Gateway). The runner gets the token with the library of the event directory, so it needs the env file of the event directory and a Vercel login (`npx vercel login`). The token is good for 6 to 12 hours; the log of the agent shows the time. Restart the agent after that. A credential in the agent's own files always wins
- **Event Directory** (`event-directory`, port 3001): the runner starts `pnpm dev --port 3001` in `apps/event-directory` (the default port 3000 is the port of the login). The app reads hosted dev services only. It needs the env file of its Vercel project at `apps/event-directory/.env.local`: `vercel env pull .env.local --environment=production` in that folder, or the file a teammate sent you (**Import…** on the Event directory env check copies it into place). Without the file, the event directory is skipped and the other services start
- **Event data needs a Vercel login**: the API token in the env file (`VERCEL_OIDC_TOKEN`) stops after 12 hours. After that, the app gets a new one by itself when the app is linked to its Vercel project and the Vercel CLI has a login on the Mac (`npx vercel login`). The runner writes the link (`apps/event-directory/.vercel/project.json`) from the project IDs in the token of the env file, when there is no link. The log of the service says which case applies
- **Chat on the home page**: the runner gives the event directory `AMATEUR_AGENT_URL=http://127.0.0.1:2000`, the agent that it started, when the app's own env files do not set that key. The home page then shows the chat, and the app sends `/eve/v1/*` to the agent. The agent needs a model credential to answer (see Agent env)
- **Old checkout**: a checkout that does not have one of the fork's apps still starts. That app is skipped
- **No Rooms tab**: the fork does not have the holds viewer

## Control API

When running, travel-runner exposes an HTTP API on `http://[::1]:19900` for programmatic control (useful from Claude Code, scripts, or CI):

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/status` | All service statuses, health, LAN mode, profile, DB mode, git branches, and `app` (`standard` or `hackathon`) |
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
