# Local database scripts

These scripts build the local Supabase database: start the stack, download the hotel catalog, reset and seed, apply migrations, verify.

Two callers use them:

- **You, by hand**, through the `pnpm db:*` commands. Nothing here needs travel-runner.
- **travel-runner**, which reads `manifest.json`, runs each step of a profile and reads the `##db:` lines the step prints.

This file is the contract between the scripts and travel-runner. Change a script and this file in the same PR. The rules for a safe change are at the end.

## Commands

| Command | What it does | Resets the database? |
|---|---|---|
| `pnpm db:setup` | Start the stack, fetch hotels, reset and seed, load hotels, copy event contracts. Flags: `--skip-hotels`, `--reset-only`, `--fresh`, `--event <id>`. | Yes |
| `pnpm db:setup:reset` | `db:setup --reset-only`: no event contract copy. | Yes |
| `pnpm db:setup:fresh` | `db:setup --fresh`: download the hotels again. | Yes |
| `pnpm db:hotels` | Download the hotel dump when no valid one is cached. `--force` downloads again. Needs no local database. | No |
| `pnpm db:reset` | `scripts/local-db.sh reset`: rebuild the workspace, replay every migration, run the repo seeds. No scenario seed, no hotels. | Yes |
| `pnpm db:migrate` | `db:reset`, then `db:gen-types`. | Yes |
| `pnpm db:apply-migrations` | `scripts/local-db.sh migrate`: apply only the migrations the database lacks. | No |
| `pnpm db:start` / `db:stop` / `db:status` | The stack itself. | No |
| `pnpm test:db-scripts` | The tests of these scripts. They use stubs: no container, database or network. | No |

The hotel download reads dev credentials from the shared `apps/booking-portal/.env` (or `apps/partner-portal/.env`): `AMATEUR_SUPABASE_URL`, `AMATEUR_SUPABASE_ANON_KEY`, `AMATEUR_SUPABASE_SIGNING_KEY`. The event contract copy reads the same keys. No URL, key or secret lives in this repo. Without the shared `.env`, `pnpm db:setup --skip-hotels` still works: it skips the hotels, and it skips the event contract copy with a warning.

## manifest.json

| Field | Meaning |
|---|---|
| `version` | Integer. travel-runner accepts 3 and 4 for the `seedScenarios` section. |
| `steps[]` | `id`, `name`, `command`, `healthCheck` (a command, or `null`), `timeoutMs`, `optional`. |
| `profiles` | Profile name → ordered list of step ids. `check-prerequisites` is first in every profile. |
| `seedScenarios.directory` | The scenario folder. This section holds only this key. |
| `runner.minVersion` | Optional. One plain `x.y.z` string: the oldest travel-runner that may reset this checkout. Not set yet; see the test in `seed-scenarios.test.mjs` before you add it. |
| `hotelDump` | Optional. `{ "url", "sha256" }` of a published hotel dump. Not set yet. |

Profiles:

| Profile | Steps |
|---|---|
| `full` | check-prerequisites, start-supabase, fetch-hotels, reset-database, load-hotels, copy-event-data, verify-data |
| `reset` | as `full`, without copy-event-data |
| `fast` | check-prerequisites, start-supabase, reset-database, verify-data |
| `migrate` | check-prerequisites, start-supabase, apply-migrations, verify-data. Never resets. |

A profile name the manifest does not have means `reset`, in the scripts and in travel-runner.

`fetch-hotels` comes before `reset-database` on purpose: a download that cannot work fails while the database still has its data.

## How a step runs

- Working directory: the repository root.
- The step command runs first. Exit code 0 means it passed.
- Then the `healthCheck` command runs, when the step has one. It is the same script with `--verify`. It reads state only and makes no remote request.
- The caller stops a step with SIGTERM (Cancel, or `timeoutMs`). `fetch-hotels` and `apply-migrations` pass the stop on to their child processes and remove partial files.
- An `optional` step that fails does not fail the profile.

## Protocol lines

A step reports to its caller with lines on stdout that start with `##db:`. Every other line is log text.

| Line | Meaning |
|---|---|
| `##db:status:running` | The step started. |
| `##db:status:done` | The step finished. |
| `##db:status:failed:<message>` | The step failed. One per run. The message is the one line the user reads: the cause and the next action. |
| `##db:progress:<fraction>:<label>` | `<fraction>` is 0 to 1 with two decimals (`0.42`). The label is short. |
| `##db:health:pass:<detail>` | A check passed. |
| `##db:health:fail:<detail>` | A check failed. A run may print several. |
| `##db:scenario:<id>:<name>` | The seed scenario of this reset. For information only. |

Rules:

- One line each. The reader splits at the first two colons only, so a message may hold colons.
- A failed step prints `status:failed` and exits non-zero.
- A health check prints `health:` lines, and may also print `status:`, `progress:` and `scenario:` lines (`reset-database --verify` reports a failure as `status:failed`). Read them all.
- Keep a `status:failed` message short: the scripts cut the long ones at 300 to 400 characters.

## Environment variables

travel-runner sets the first four for every step and health check. By hand, all are optional.

| Variable | Read by | Meaning |
|---|---|---|
| `TRAVEL_DB_PROFILE` | check-prerequisites, reset-database | The profile of this run. With a hotel profile, check-prerequisites also checks the hotel source. reset-database records `hotels_skipped` from it. `check-prerequisites.mjs --profile <name>` wins over it. `pnpm db:setup` sets it from its flags, over an exported value. |
| `TRAVEL_SEED_SCENARIO` | reset-database, load-hotels | The seed scenario id. Empty means the default scenario. |
| `TRAVEL_HOTEL_DUMP` | fetch-hotels, load-hotels, setup-local | The path of the hotel dump. Default: `data/travel_organizations.sql` in the checkout. A valid dump in the checkout moves to this path once. |
| `TRAVEL_RUNNER_FLAVOR` | reset-database | Which travel-runner app built the database. Stored in `seed_state.flavor`. |
| `TRAVEL_HOTEL_DUMP_URL`, `TRAVEL_HOTEL_DUMP_SHA256` | fetch-hotels | A published dump to download in place of paging dev. Set both. They win over `hotelDump` in the manifest. |
| `FB_BACKEND_REF`, `FB_AMATEUR_BACKEND_DIR`, `FB_REALTIME_VERSION` | `scripts/local-db.sh` | See the header of that script. |

## Exit codes

| Code | Scripts | Meaning |
|---|---|---|
| 0 | all | Passed. |
| 1 | all | Failed for a reason the `status:failed` or `health:fail` line names. |
| 2 | `local-db.sh`, `dump-travel-organizations.py` | Wrong arguments. |
| 3 | `apply-migrations.mjs --check`, `local-db.sh migrate` | Refused; nothing was changed. The database lacks a bootstrap migration, has versions this checkout does not have, or cannot be read. The step itself reports this as `status:failed` and exits 1. |
| 10 | check-prerequisites, fetch-hotels, load-hotels | No dev credentials in the shared `.env`. |
| 11 | same | The source refused the request (HTTP 401 or 403). |
| 12 | same | Network or timeout. |
| 13 | same | The download is incomplete, or dev has no hotel rows. Nothing was cached. |
| 14 | load-hotels | The local database is not reachable, or has no `fb_travel.travel_organizations` table. |
| 128 + signal | fetch-hotels, `dump-travel-organizations.py` | Stopped by a signal. |

check-prerequisites exits with a hotel code (10 to 13) only when the hotel source is its only failure. With Docker, the Supabase CLI or `node_modules` missing it exits 1.

`verify-data` always exits 0: it prints row counts.

## Hotel dump files

| File | Content |
|---|---|
| `<dump>` | SQL: one `INSERT INTO fb_travel.travel_organizations (...)` line per row, with every remote column. |
| `<dump>.meta.json` | `rows`, `columns`, `generatedAt` (ISO 8601), `sourceRef`, and `sha256` for a published dump. |
| `<dump>.<pid>.partial` | A download in progress. It is renamed to `<dump>` only when complete. |

A dump is valid when the meta file exists and the INSERT count equals `rows`. A dump from before the meta file counts when its own `-- Total rows:` header equals its INSERT count; the meta file is then written for it.

load-hotels compares the dump's columns with the live table after the reset. It drops columns only the dump has. When the table needs a column the cached dump lacks, it downloads once more.

## What a reset records

`reset-database` writes one row to `travel_runner.seed_state`. `pnpm db:reset` alone does not: after it the table does not exist.

| Column | Meaning |
|---|---|
| `scenario_id`, `effective_variables`, `applied_at` | The seed scenario and when it was applied. |
| `checkout_path`, `branch`, `backend_sha`, `flavor` | Who built the database. NULL when not known. |
| `hotels_skipped` | `true`: the profile has no hotel step. `false`: the profile loads hotels. NULL: no profile was named. load-hotels sets it to `false` when it starts, so a later hotel load after a `fast` reset counts as asking for hotels. |

Columns are added with `ADD COLUMN IF NOT EXISTS`. A reader must accept a table that lacks the newer columns.

## Changing the contract

Teammates run older copies of travel-runner. Keep each change safe for them:

- Add; do not rename or remove. A new step id, profile, manifest key, protocol line type or `seed_state` column is safe: older readers skip what they do not know.
- Keep the `full`, `reset` and `fast` profile names and the `##db:` line forms above.
- Keep the meaning of exit codes 10 to 14.
- A script must work with none of the environment variables set.
- Set `runner.minVersion` only after the travel-runner release that reads it has reached every teammate, in its own PR.
