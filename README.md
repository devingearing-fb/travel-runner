# travel-runner

macOS menu bar app that orchestrates the Fastbreak travel booking local development environment.

## Quick Start

```bash
./build.sh --run
```

On first launch, a setup wizard guides you through configuring repo paths and verifying prerequisites.

## What It Does

- **One-click startup**: Starts Supabase, db migrations, yalc link, universal-login, Stripe CLI, and the travel portal in dependency order
- **Health monitoring**: Color-coded status dot in the menu bar (green/amber/red/gray)
- **Stripe secret injection**: Captures `whsec_` from Stripe CLI stdout, writes to `.env.local` + serves via HTTP registry
- **Migration detection**: Auto-runs `db:reset` when new migration files are detected
- **Console tabs**: Live logs for Stripe, Booking Portal, and Universal Login with Pino JSON formatting
- **Crash recovery**: Auto-restarts failed services with exponential backoff
- **LAN mode**: Toggle to make all services accessible from other devices (mobile testing)
- **Sleep/wake**: Re-probes services after macOS wake

## Control API

When running, travel-runner exposes an HTTP API on `http://localhost:19900` for programmatic control (useful from Claude Code, scripts, or CI):

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/status` | All service statuses, health, LAN mode |
| `GET` | `/api/logs/{serviceId}?lines=N` | Last N log lines (default 50) |
| `POST` | `/api/restart/{serviceId}` | Restart a service |
| `POST` | `/api/clear-cache-restart/{serviceId}` | Clear `.next` cache + restart |
| `POST` | `/api/start-all` | Start all services |
| `POST` | `/api/stop-all` | Stop all services |
| `POST` | `/api/toggle-lan` | Toggle LAN mode for mobile testing |

**Service IDs:** `supabase`, `universal-login`, `stripe`, `travel-portal`, `yalc-link`

### Examples

```bash
# Check what's running
curl http://localhost:19900/api/status

# Get booking portal logs
curl http://localhost:19900/api/logs/travel-portal?lines=50

# Clear Next.js cache and restart the portal
curl -X POST http://localhost:19900/api/clear-cache-restart/travel-portal

# Toggle LAN mode for phone testing
curl -X POST http://localhost:19900/api/toggle-lan

# Restart universal login
curl -X POST http://localhost:19900/api/restart/universal-login
```

## Configuration

Config lives at `~/.config/travel-runner/services.json`. The setup wizard creates it on first launch. Edit manually or use the Settings gear icon in the app.

## Building

Requires Swift 6+ (Xcode or Command Line Tools).

```bash
./build.sh              # Build TravelRunner.app
./build.sh --run        # Build + launch
./build.sh --install    # Build + copy to /Applications
```

## Tech Stack

Swift 6, SwiftUI, [FlyingFox](https://github.com/swhitty/FlyingFox) (embedded HTTP server), SPM
