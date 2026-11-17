# monolith-snapshot

The parts of fb-travel-monolith that Travel Runner reads, pinned, so that the
contract tests run the same way on every Mac and in CI. They need no checkout
beside this repo.

Taken from fb-travel-monolith at `3724e3837` (branch `fix/travel-runner-friction`).

| File | What it is |
|---|---|
| `scripts/db/manifest.json` | The manifest, as it is. |
| `scripts/db/README.md` | The script contract (profiles, `##db:` lines, exit codes), as it is. |
| `scripts/local-db.sh` | An excerpt: the loop that gives the two backend bootstraps their local versions. |
| `supabase/config.toml` | An excerpt: the project id. |
| `supabase/seeds/scenarios/*/scenario.json` | The seed scenario descriptors, as they are. The `.sql` files are placeholders: no seed data is copied. |
| `recorded/env-check-booking.json` | The output of `node scripts/env-check.mjs --json --app booking --file <candidate>` for a candidate that sets `LITEAPI_API_KEY` and `STATSIG_SERVER_KEY`. Key names only; the file path is replaced. |

No URL, key, secret or data dump goes in here: this repo is public.

## Run the tests against a real checkout

```bash
TR_INTEGRATION=1 swift test
```

The tests then read `../fb-travel-monolith` (or the folder in `TR_MONOLITH_DIR`)
in place of this snapshot, and the tests that run monolith scripts run too. A
missing checkout fails the run.

## Refresh the snapshot

When the monolith changes the contract, copy the files above again, keep the
excerpts to the same lines, update the commit above, and run `swift test`.
