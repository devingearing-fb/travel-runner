# travel-runner

macOS menu bar app that orchestrates the Fastbreak travel booking local development environment.

## Install (teammates)

Do these in order on a new Mac. The fb-travel-monolith README ("Once per machine") has the same prerequisites.

1. **Install the prerequisites.** The commands use [Homebrew](https://brew.sh):
   ```bash
   brew install node@22                       # Node 22; or: nvm install 22 (the monolith has .nvmrc)
   echo 'export PATH="/opt/homebrew/opt/node@22/bin:$PATH"' >> ~/.zshrc   # node@22 is keg-only; skip with nvm
   export PATH="/opt/homebrew/opt/node@22/bin:$PATH"                     # same, for this terminal
   npm install -g corepack && corepack enable pnpm   # Homebrew's Node has no corepack; nvm's Node 22 does
   brew install --cask orbstack               # Docker; or Docker Desktop. Open it once.
   brew install python                        # Python 3 for the database setup; the Xcode python3 stub does not work
   brew install stripe/stripe-cli/stripe      # optional, for payment webhooks
   ```
   Then check out `fb-travel-monolith` and `fb-amateur-universal-login`, set the GitHub Packages token (`pnpm config set --location=user "//npm.pkg.github.com/:_authToken" "$FB_TOOLKIT_TOKEN"`), and run `pnpm install` in the monolith and `npm install` in universal login. In a new terminal, `node -v` says v22 or newer, `pnpm -v` says 10.x, and `docker info` answers. Tools from nvm, fnm, Volta or mise are fine: the runner reads your `~/.zshrc` to find them.
2. **Download Travel Runner.** Get `TravelRunner-<version>.zip` from the [latest release](https://github.com/devingearing-fb/travel-runner/releases/latest). It runs on Apple Silicon Macs.
3. **Move it to /Applications.** Unzip it and move `TravelRunner.app` to `/Applications` before you open it. Opened from Downloads, macOS runs a read-only copy that cannot update, and the runner shows a banner that says to move it.
4. **Find it in the menu bar.** The app has no Dock icon. Click its menu-bar icon to show or hide the window. Control-Shift-T does the same; from other apps it works only after you allow Travel Runner in System Settings > Privacy & Security > Accessibility.
5. **Run the wizard.** It opens on the first launch. Drop your Codebases folder on it, or browse to each checkout: `fb-travel-monolith` is required, universal login too; stream-services and travel-load-test are optional. **Check Environment** then runs each check. A failed check has a fix button or a command to copy. **Re-check All** runs them again.
6. **Bring in the two shared `.env` files.** The booking and partner apps each need `apps/<app>/.env` with the shared dev values. On the Environment Check (later: Settings → Reconfigure Repos…), use **Import…** on the booking and partner rows for a file a teammate sent you, or **Pull from Doppler** if you have Doppler access. The old file is kept as `.env.bak-<date>`. The runner never stores these values.
7. **Press Start.** Pick a profile in Settings (`booking`, `partner` or `both`) and click **Start**. The first Start pulls the Supabase images, builds the local database and downloads the hotel catalog (about 285 MB), so it takes several minutes, more on a slow network. Later starts are much faster. The menu-bar dot turns green when every service answers.
8. **Something failed?** See [Troubleshooting](#troubleshooting) and [Something broke](#something-broke).

### Troubleshooting

| What you see | What to do |
|---|---|
| A check says node or pnpm was not found | Open a new terminal and run `node -v` and `pnpm -v`. If they work there, press **Re-check All**: the runner reads your shell again. Diagnostics shows where each tool was found. |
| Docker or OrbStack does not answer | Open OrbStack (or Docker Desktop) and wait until it is up, then press **Retry**. The runner waits 120 s for a runtime it opens. |
| `pnpm install` fails with 401 for `@fastbreak-amateur/fb-toolkit` | The GitHub Packages token is missing or old. Use **Set token** on the registry check. |
| The booking or partner `.env` check fails | Import the file a teammate sent you, or **Pull from Doppler**. `pnpm env:check` in the monolith names the missing keys. |
| Folder access fails | macOS refused the runner a folder. Use **Grant access in System Settings**, then press **Re-check All**. |
| "Travel Runner is already running from …" | Two copies fight over the same ports. Quit the other one, or use the one in `/Applications`. |
| A database step fails | The step shows its error and its log. Use its button, then **Report** (below). |
| The hotkey does nothing in other apps | Allow Travel Runner in System Settings > Privacy & Security > Accessibility. |

## Developer quick start

```bash
./build.sh --run
```

On first launch, a setup wizard guides you through configuring repo paths and verifying prerequisites. Point it at your `fb-travel-monolith` checkout (the pnpm+turbo monorepo with `apps/booking-portal`, `apps/partner-portal`, `packages/travel-data`, and the root `supabase/` and `scripts/`), plus fb-amateur-universal-login, stream-services and travel-load-test. The old sibling repos (travel-booking-portal, fb-amateur-travel-partner-portal, fb-travel-data) are no longer supported; a version 2 config is migrated by finding the monorepo next to the old booking-portal path.

## What It Does

- **One-click startup**: Starts the selected profile in dependency order — `booking` (Supabase, Universal Login, Stripe, booking portal on :3002), `partner` (Supabase, Universal Login, partner portal on :3006), `both` (default), or `full` (adds cache verification, stream-services, QStash, and Sequin; experimental)
- **Health monitoring**: Color-coded status dot in the menu bar (green/amber/red/gray)
- **Health section**: every setup check of the first-run wizard, with its Fix and Import… buttons, and where each tool was found. The launch runs the fast checks; the network checks (GitHub Packages, Stripe, pnpm) run when Health opens. The preflight of a start runs the fast checks in parallel, 3 s each, and gives a Node check that times out one more try with the Health limit; Node must match `engines.node` of the monorepo. Status says "N setup items need attention — Open Health" while a check fails
- **Stripe secret injection**: Captures `whsec_` from Stripe CLI stdout, writes to the runner block in `apps/booking-portal/.env.local` + serves via HTTP registry
- **Stripe without a login**: `stripe listen` uses the `sk_test_` `STRIPE_SECRET_KEY` of `apps/booking-portal/.env` (or `.env.local`), passed as `STRIPE_API_KEY` in its environment. Without a test key it uses your own `stripe login`. The Stripe row says which. A live key is never used.
- **Env management**: each app's shared dev values live in the monolith at `apps/<app>/.env` (a teammate's copy, brought in with **Import…** in Health, or `pnpm env:pull` with Doppler access); the runner never holds them. `pnpm env:check` in the monolith says whether a copy is complete. The runner owns a marked block at the end of each app's `.env.local` (`# >>> travel-runner: managed block, ...` to `# <<< travel-runner`) with local Supabase, URL and login overrides
- **Migration detection**: Sets up an empty database by itself (`scripts/db/manifest.json` `reset` profile). A database with data is never reset without asking: when it lacks migrations or has versions the branch does not have, a banner offers **Apply migrations** (the `migrate` profile, which never resets; hidden when the manifest has no such profile) and **Reset and reseed…**. A failed apply changes nothing more and leaves both choices. Settings → "Reset the database when migrations change" (off by default) brings back the automatic reset, but never for a database that another checkout built
- **Shared code**: `packages/travel-data` hot-reloads into both apps — nothing to build or link
- **Console tabs**: Live logs for Stripe, Booking Portal, and Universal Login with Pino JSON formatting
- **Crash recovery**: Auto-restarts failed services with exponential backoff, and stops after 3 failures in a minute (circuit breaker). A service that someone stops from outside (`kill`) comes back without a crash report
- **LAN mode**: Toggle to make all services accessible from other devices (mobile testing); the web servers listen on all addresses, both apps' runner blocks get the address of the default-route interface, and a network change with a new address applies it again
- **Database mode**: Toggle between local Supabase and hosted dev (needs each profile app's shared `.env`)
- **Sleep/wake**: Re-probes services after macOS wake, one pass per wake
- **Rooms tab**: For one event and hotel, shows how many rooms of each room type are booked, held and free on each night, and who holds them. A switch selects the local stack or dev. The tab is read-only. It shows the page of the monolith's holds viewer (`scripts/holds-viewer`): the copy in your checkout, or the copy of `origin/dev` when your branch does not have it. Dev needs only the shared `apps/<app>/.env`, not Doppler. The viewer runs while the tab is open and stops 10 minutes after it closes. `defaults write ai.fastbreak.travel-runner holdsViewerPath <folder>` makes the tab use a copy from another folder; `defaults delete ai.fastbreak.travel-runner holdsViewerPath` removes that

## Something broke

1. Read the red card on Status, or the banner at the top. A failed service shows its last log lines; a failed DB step shows its error and its log (the terminal button).
2. Try the button on it: **Restart**, **Clear Cache**, or **Retry** on a DB step.
3. Still broken? Press **Report**. It is on the red card, on a failed DB step, on the error banner, in an issue on the Issues tab, under Diagnostics, and in the menu bar menu (**Report a Problem…**).
4. The runner saves `TravelRunner-report-<yyyyMMdd-HHmm>-v<version>.zip` to Downloads, shows it in Finder, and copies a three-line summary. If macOS does not let it write to Downloads, the zip goes to `~/Library/Application Support/Travel Runner/reports` instead; to use Downloads, allow it in System Settings > Privacy & Security > Files and Folders.
5. Paste the summary in Slack, attach the zip, and send it to Devin.

The report holds `diagnostics.json` (the app version, macOS, the tools and their PATH, the profile, the database mode, the start checks, the DB setup steps, the pending migrations, the repo paths and each service), the last 2000 lines of each log, the newest open issues, and `events.jsonl`. Secret values are masked (`‹redacted:kind›`). Open the zip and read it before you share it. Nothing is sent anywhere by the app.

Where the files are on your Mac:

- **Logs**: `~/Library/Logs/Travel Runner/<service id>.log`, with a time on each line. They are kept for 14 days.
- **Issues**: `~/Library/Application Support/Travel Runner/issues`, one folder for each failure, with `issue.json`, `diagnostics.json` and the logs. Turn issue capture on or off in Settings. It saves failure details on this Mac only.

## Travel Runner Hackathon

The same source makes a second app, Travel Runner Hackathon, for the hackathon fork (`SnapBuild-2026/fb-travel-monolith-hackathon`). `FLAVOR=hackathon ./build.sh` builds it; `FLAVOR=hackathon ./release.sh <version>` releases it (tag `hackathon-v<version>`, never the latest release; its update feed is the fixed release `hackathon-appcast`).

- **Own state**: bundle ID `ai.fastbreak.travel-runner-hackathon`, config in `~/.config/travel-runner-hackathon/`, control API on port **19901**, issues in `~/Library/Application Support/Travel Runner Hackathon/issues`, hotkey Control-Shift-H. A person can have the two apps
- **One stack at a time**: the two apps use the same service ports. An app does not start a stack while the other app runs one
- **Setup** takes only a checkout that has `apps/amateur-agent`, so a folder with the two repos gives each app its own repo
- **Amateur Agent** (`amateur-agent`, port 2000): the runner starts `pnpm exec eve dev --no-ui` in `apps/amateur-agent`. An `eve dev` (`pnpm dev`) in a terminal then opens the REPL on that server. eve needs Node 24 or later: when the default Node is older, the runner uses one from nvm, fnm, mise, Volta, asdf or Homebrew (`node@24`) for the agent only. With no such Node, or without the packages, the agent is skipped and the portals start
- **Agent env**: the agent works without its own env file. For a value that `apps/amateur-agent/.env.local` does not set, the runner gives the agent, as process env: the `AMATEUR_SUPABASE_*` keys of `apps/booking-portal/.env`; `PXI_API_URL`, `NEXT_PUBLIC_REGISTRATION_BASE_URL` and `MAPBOX_ACCESS_TOKEN` of the event directory's env (the event tools of the agent need `PXI_API_URL`); and a token of the event directory's Vercel project (see the next item). The runner does not set `EVENT_DIRECTORY_ORIGIN`, so the links of the agent stay relative. If a teammate sent you the env file of the agent, use **Import…** on the Agent env row of the Environment Check, or copy it to `apps/amateur-agent/.env.local`; its values win. Do not paste the Doppler line of `AMATEUR_SUPABASE_SIGNING_KEY` into that file: eve cannot read its escaped quotes (single quotes around the JSON are correct)
- **Token and model credential of the agent**: the event tools need a `VERCEL_OIDC_TOKEN` of the event directory's Vercel project, and eve also uses it for the AI Gateway when no file gives the agent `AI_GATEWAY_API_KEY`. In that case the project pays for the model calls. The runner gives the agent a new token when the agent's own files have none, or have one that stopped (the token of an env file stops after 12 hours). The runner gets the token with the library of the event directory, so it needs the env file of the event directory and a Vercel login (`npx vercel login`). The token is good for 6 to 12 hours; the log of the agent shows the time. Restart the agent after that. The runner gives no token when the agent's folder has its own Vercel project link: the agent then gets its tokens itself
- **Platform Core** (`platform-core`, port 3007): the runner starts `pnpm dev:dev` in `apps/platform-core`, the script that `pnpm dev:platform-core` of the fork runs. The fork sets the port and the env file of the app in that script (`dotenv -e .env.dev -- next dev --turbopack -p 3007`), and the runner reads the two from there. When the fork changes the port, quit the runner and open it again; no new version of the runner is necessary. The app needs its env file at `apps/platform-core/.env.dev`, with `LOGIN_URL` and `NEXT_PUBLIC_FASTBREAK_DOMAIN` (the file a teammate sent you; **Import…** on the Platform core env check copies it into place). The app uses the database and the login that this file names. The runner writes no env for it. Without the app, its packages or its env, platform core is skipped and the other services start; its log says why
- **Event Directory** (`event-directory`, port 3004): the runner starts `pnpm dev --port 3004` in `apps/event-directory` (the default port 3000 is the port of the login, and 3001 is the usual port of platform core). The app reads hosted dev services only. It needs the env file of its Vercel project at `apps/event-directory/.env.local`: `vercel env pull .env.local --environment=production` in that folder, or the file a teammate sent you (**Import…** on the Event directory env check copies it into place). Without the file, the event directory is skipped and the other services start
- **Event data needs a Vercel login**: the API token in the env file (`VERCEL_OIDC_TOKEN`) stops after 12 hours. After that, the app gets a new one by itself when the app is linked to its Vercel project and the Vercel CLI has a login on the Mac (`npx vercel login`). The runner writes the link (`apps/event-directory/.vercel/project.json`) from the project IDs in the token of the env file, when there is no link. The log of the service says which case applies
- **Chat on the home page**: the runner gives the event directory `AMATEUR_AGENT_URL=http://127.0.0.1:2000`, the agent that it started, when the app's own env files do not set that key. The home page then shows the chat, and the app sends `/eve/v1/*` to the agent. The agent needs a model credential to answer (see Agent env)
- **Chat in the booking portal**: the runner gives the booking portal the same `AMATEUR_AGENT_URL=http://127.0.0.1:2000`, when the portal's own env files do not set that key and the agent is not skipped. The log of the portal shows the value
- **Old checkout**: a checkout that does not have one of the fork's apps still starts. That app is skipped
- **No Rooms tab**: the fork does not have the holds viewer

## Control API

When running, travel-runner exposes an HTTP API on `http://localhost:19900` (it listens on both `127.0.0.1` and `[::1]`) for programmatic control (useful from Claude Code, scripts, or CI):

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/status` | All service statuses, health, LAN mode, profile, DB mode, git branches, `app` (`standard` or `hackathon`), and `configured` (false until a `services.json` loads) |
| `GET` | `/api/preflight` | Runs the start checks that change nothing (the fast setup checks of Health, ports, folders) and gives each result |
| `GET` | `/api/health` | Health and its reason |
| `GET` | `/api/services` | Each service with its phase, reason and fix |
| `GET` | `/api/diagnostics` | The diagnostics snapshot of an issue, secrets masked |
| `GET` | `/api/events` | The events that made no issue (`events.jsonl`) |
| `GET` | `/api/logs` | The log ids, with each DB step as `db-setup-<stepId>` |
| `GET` | `/api/logs/{id}?lines=N` | Last N log lines (default 50) of a service or a DB step |
| `POST` | `/api/restart/{serviceId}` | Restart a service; for `supabase`, `?stack=1` stops and starts the containers too |
| `POST` | `/api/restart-cascade/{serviceId}` | Restart a service and its dependents |
| `POST` | `/api/clear-cache-restart/{serviceId}` | Clear `.next` cache + restart (`travel-portal`, `partner-portal`) |
| `POST` | `/api/start-all` | Start the active profile's services |
| `POST` | `/api/stop-all` | Stop all services |
| `POST` | `/api/toggle-lan` | Toggle LAN mode for mobile testing |
| `POST` | `/api/toggle-db-mode` | Toggle local Supabase / hosted dev database |
| `GET` | `/api/profile` | Active profile, its services, available profiles |
| `POST` | `/api/profile/{booking\|partner\|both\|full}` | Set the run profile (400 on unknown) |
| `POST` | `/api/db-reset` | Reset the DB (manifest `reset` profile, selected seed scenario) |
| `POST` | `/api/db-setup` | Run the DB setup pipeline; optional body `{"profile": "full\|reset\|fast\|migrate"}` (`migrate` never resets) |
| `POST` | `/api/db-setup/retry/{stepId}` | Re-run the pipeline from a step |
| `POST` | `/api/db-setup/step/{stepId}` | Run a single step |
| `POST` | `/api/db-setup/cancel` | Cancel a running pipeline |
| `GET` | `/api/db-setup/status` | Pipeline state with per-step progress (a fraction from 0 to 1) |
| `GET` | `/api/debug/status` | Whether issue capture is on, the open count and the issue folder |
| `GET` | `/api/debug/issues` | List open debug-tracking issues |
| `POST` | `/api/debug/issues` | Capture an issue; body `{"description": "..."}` |
| `POST` | `/api/debug/issues/close/{id}` | Close an issue; optional body `{"resolution": "..."}` |

An action answers `202` when it was accepted, `400` for a parameter or body it cannot read, `404` for an unknown service, step or route, `409` when it cannot run now (with the reason in `error`), and `422` for a reset with no valid seed scenario. `.claude/skills/travel-runner-api/SKILL.md` has the full table.

The API listens from launch, also before the setup wizard has saved a config.

The checkout names the oldest runner that may reset it: `"runner": { "minVersion": "x.y.z" }` in `scripts/db/manifest.json`. A dev build (`./build.sh`) is never blocked. An older release still starts the services, but `db-reset`, `db-setup`, `retry` and `step` answer `409` with `{"ok": false, "error": "runner_too_old", "message": "...", "download_url": "..."}`, and `/api/status` has a `reset_blocked` text.

Each service in `/api/status` has `phase` and `pid`. A failed service adds `reason` (what is wrong and what to do) and, when its log shows one, `likely_cause` (the log line). A skipped service adds `skip_reason`. `last_probe` is the last check of the startup probe, such as `connection refused` or `HTTP 404`.

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

Settings → Reconfigure Repos applies new paths at once when the stack is stopped. While the stack runs, the app asks: "Stop and apply" stops the stack and loads the new paths; "Apply at next launch" keeps the stack and loads them at the next launch.

Every DB setup step gets `TRAVEL_SEED_SCENARIO`, `TRAVEL_DB_PROFILE` (the profile of the pipeline), `TRAVEL_RUNNER_FLAVOR` and `TRAVEL_HOTEL_DUMP`. The hotel dump (about 285 MB) is kept in `~/Library/Application Support/Travel Runner/hotels/`, not in the checkout, so a second checkout or a worktree does not download it again. The fetch script moves a valid dump from `data/` there once.

## Building

Requires Swift 6+ (Xcode or Command Line Tools).

```bash
./build.sh              # Build TravelRunner.app
./build.sh --run        # Build + launch
./build.sh --install    # Build + copy to /Applications
```

`swift test` runs the tests with fakes: no dev stack, database or network. The tests of the monolith contract (manifest, `##db:` lines, bootstrap migrations) read a pinned snapshot in `Tests/Fixtures/monolith-snapshot`. `TR_INTEGRATION=1 swift test` runs them against `../fb-travel-monolith` (or `TR_MONOLITH_DIR`) and also runs the tests that call monolith scripts.

Only one copy of the app runs at a time. A second copy says where the first one runs from, and quits. A release copy outside `/Applications` (or `~/Applications`) shows a banner once for each place: move the app to `/Applications`, so that updates install and old copies do not start by mistake.

No test starts two real copies. Check these by hand in a built app before a release:

- With one copy open, open a second copy from another folder. The second copy shows the alert with the path and the version of the first.
- "Show the running copy" opens the window of the first copy, and the second copy quits.
- "Quit" in the alert leaves the services and the ports of the first copy up.
- With `TRAVEL_RUNNER_SMOKE=1`, the second copy shows no alert: it prints the message and exits with code 75.

Releases: see [RELEASING.md](RELEASING.md). A release goes to the canary channel first (`./release.sh <version>`), then to everyone (`./release.sh --promote <version>`). `scripts/smoke.sh <App.app>` starts a built app with an empty home folder and checks that it answers. `scripts/clean-shell-check.sh [monolith]` runs the monolith's first database step, and reads the imports of its Python scripts, with only the tools of the install steps above; `release.sh` refuses to publish unless it and `swift test` pass.

## Tech Stack

Swift 6, SwiftUI, [FlyingFox](https://github.com/swhitty/FlyingFox) (embedded HTTP server), SPM
