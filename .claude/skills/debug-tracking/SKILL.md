---
name: debug-tracking
description: Interact with travel-runner's debug-tracking system to check for open issues, create new issues, close resolved issues, and detect recurring error patterns. Use before starting any debugging workflow.
trigger: when checking environment health, encountering errors, diagnosing failures, or when the user reports something is broken
---

# Debug Tracking

travel-runner automatically captures service crashes, circuit breaker trips, DB setup failures, and probe timeouts as structured debug issues. These issues live on disk and are queryable via the HTTP API at **http://localhost:19900**. Always check for existing issues before starting a manual debugging session.

## Quick decision tree

Before debugging anything:
1. Check for existing issues: `curl -s http://localhost:19900/api/debug/issues` (returns open issues only)
2. If an issue exists for this service/error, read its folder on disk for context (see On-disk structure below)
3. If no matching issue, proceed with diagnosis — the system auto-captures errors

After fixing something:
1. Close the issue with a resolution description

## Checking availability

```bash
curl -sf http://localhost:19900/api/debug/issues > /dev/null 2>&1 && echo "available" || echo "not available"
```

If not available, travel-runner may not be running. Fall back to reading on-disk files directly (see On-disk structure below). Debug tracking is only active when `~/Desktop/debug-tracking/config.json` exists with `"enabled": true`; otherwise the list endpoint returns `[]` and close returns `{"ok":false,"error":"debug tracking not enabled"}`.

## Endpoints

The API has exactly three debug routes: list open issues, create an issue, and close an issue. There is no detail, logs, or filter endpoint — read those from disk.

### GET /api/debug/issues

List **open** issues. Takes no query parameters (no status, service, or category filter); closed issues are only on disk.

```bash
curl -s http://localhost:19900/api/debug/issues | python3 -m json.tool
```

**Response shape** (all values are strings):

```json
[
  {
    "id": "20260510T143200_service-crash-travel-portal",
    "summary": "service_crash [travel-portal]: travel-portal exited with code 134",
    "severity": "error",
    "status": "open",
    "service_id": "travel-portal",
    "category": "runtime",
    "created_at": "2026-05-10T14:32:00.123Z",
    "recurrence_count": "0"
  }
]
```

The ID is `yyyyMMdd'T'HHmmss` (local time) + `_` + the trigger (underscores as dashes) + `-<service_id>` when there is one. `service_id` is `""` when the issue has no service (e.g. manual captures). A repeat of the same error within the dedup window (7 days by default) bumps `recurrence_count` on the open issue instead of creating a new one.

### POST /api/debug/issues

Create a manual issue. Use for bugs that auto-capture doesn't catch (logic errors, cross-service issues, subtle regressions). The only body field is `description`; it defaults to `"Manual capture via API"` when missing.

```bash
curl -s -X POST http://localhost:19900/api/debug/issues \
  -H "Content-Type: application/json" \
  -d '{"description": "Guest assignment silently drops when booking has 0 capacity — assignGuest returns success but guest row not created"}'
```

The issue is created asynchronously with trigger `manual` and no service, so no service logs are captured — put the service, steps to reproduce and error message in the description. A state snapshot of all services is still written.

Response: `{"ok":true}` (the new issue ID is not returned — list the issues to find it)

### POST /api/debug/issues/close/{id}

Close a resolved issue. Updates `issue.json` (`status`, `resolution`, `resolved_at`) and moves the on-disk folder from `open/` to `closed/`. The body is optional; `resolution` defaults to `"Closed via API"`.

```bash
curl -s -X POST http://localhost:19900/api/debug/issues/close/20260510T143200_service-crash-travel-portal \
  -H "Content-Type: application/json" \
  -d '{"resolution": "Cleared .next cache and restarted; turbopack cache corruption"}'
```

Response: `{"ok":true}`, or `{"ok":false,"error":"issue not found"}` when no open issue has that ID.

## Triggers

Each issue records what captured it in its `trigger` field (and in its ID). Auto-capture per trigger can be turned off under `auto_capture` in `~/Desktop/debug-tracking/config.json`.

| Trigger | Auto-captured | Description |
|----------|---------------|-------------|
| `service_crash` | yes | Process exited non-zero or received fatal signal |
| `circuit_breaker` | yes | Circuit breaker tripped after repeated failures |
| `db_setup_failure` | yes | Supabase migration or seed failure during startup |
| `preflight_failure` | yes | Preflight check failed (port conflict, missing dep) |
| `probe_timeout` | yes | Health probe exceeded timeout without response |
| `manual` | no | Created via `POST /api/debug/issues` — logic bugs, cross-service problems |

The stored `severity` and `category` fields are currently always `"error"` and `"runtime"`; use `trigger` to tell issues apart, and use the severity guide below when describing an issue.

## Severity guide

| Severity | Criteria | Examples |
|----------|----------|----------|
| `critical` | Service down, data loss risk, blocks all work | Portal crash loop, DB corruption, migration failure |
| `high` | Major feature broken, workaround exists but painful | Guest assignment fails, booking creation errors |
| `medium` | Feature degraded, easy workaround available | Slow queries, intermittent UI glitch |
| `low` | Cosmetic or minor, no functional impact | Logging noise, deprecation warning |

## When to create manual issues

- Subtle logic bugs not caught by auto-capture (e.g., state machine edge cases)
- Cross-service issues where the symptom is in one service but the cause is in another
- Errors you diagnosed from logs but that didn't trigger auto-capture
- Regressions you noticed during testing that aren't causing crashes

## When NOT to create issues

- Transient errors that resolve on retry (network blips, cold-start timeouts)
- Cache problems solved by `clear-cache-restart` — just restart, don't track
- Issues you fix immediately in the same session — no value in tracking what's already resolved

## Diagnostic workflows

### "Something is broken"

1. `GET /api/debug/issues` — check for auto-captured open issues first
2. If found, read `~/Desktop/debug-tracking/open/{id}/issue.json` for pre-captured context (error message, trigger, recurrence) and `state-snapshot.json` for service states
3. Review the captured logs: `logs-{service_id}.txt` and `logs-all.txt` in the same folder
4. If no issue found, fall back to `GET /api/status` and `GET /api/logs/{serviceId}` via the travel-runner-api skill

### Recurring issue

1. Check `recurrence_count` in `GET /api/debug/issues` — repeats of the same error bump it on the open issue
2. For history, look in `~/Desktop/debug-tracking/closed/` for folders with the same trigger and service in the name (e.g. `ls ~/Desktop/debug-tracking/closed/ | grep service-crash-travel-portal`)
3. Read `issue.json` in those closed folders — the `resolution` field holds prior fixes
4. Reference the pattern in your diagnosis and note it when creating or closing the new issue

### Post-fix cleanup

1. `GET /api/debug/issues` — find the issue you just resolved
2. `POST /api/debug/issues/close/{id}` with a clear resolution description
3. Include what fixed it and why it broke — this helps with future recurring issue detection

## On-disk structure

Issues live at `~/Desktop/debug-tracking/open/` and `~/Desktop/debug-tracking/closed/`. Each issue is a folder named by its ID containing:

```
~/Desktop/debug-tracking/
  config.json             # enabled flag, auto_capture toggles, log_lines, dedup_window_seconds
  open/
    20260510T143200_service-crash-travel-portal/
      issue.json            # Full issue metadata (error_message, trigger, recurrence, resolution)
      logs-travel-portal.txt  # Last lines of the failing service's log (secrets redacted)
      logs-all.txt          # Combined recent logs of the captured services
      state-snapshot.json   # Service states at time of capture
  closed/
    20260509T091500_probe-timeout-supabase/
      issue.json
      logs-supabase.txt
      logs-all.txt
      state-snapshot.json
```

Read the files directly for anything beyond the open-issue list, or when the API is not available (travel-runner not running):

```bash
# List open issues
ls ~/Desktop/debug-tracking/open/

# Read a specific issue
cat ~/Desktop/debug-tracking/open/20260510T143200_service-crash-travel-portal/issue.json | python3 -m json.tool

# Read captured logs
cat ~/Desktop/debug-tracking/open/20260510T143200_service-crash-travel-portal/logs-travel-portal.txt
```
