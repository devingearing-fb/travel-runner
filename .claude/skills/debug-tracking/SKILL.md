---
name: debug-tracking
description: Interact with travel-runner's debug-tracking system to check for open issues, create new issues, close resolved issues, and detect recurring error patterns. Use before starting any debugging workflow.
trigger: when checking environment health, encountering errors, diagnosing failures, or when the user reports something is broken
---

# Debug Tracking

travel-runner automatically captures service crashes, circuit breaker trips, DB setup failures, and probe timeouts as structured debug issues. These issues live on disk and are queryable via the HTTP API at **http://localhost:19900**. Always check for existing issues before starting a manual debugging session.

## Quick decision tree

Before debugging anything:
1. Check for existing issues: `curl -s http://localhost:19900/api/debug/issues?status=open`
2. If an issue exists for this service/error, read the detail for context
3. If no matching issue, proceed with diagnosis — the system auto-captures errors

After fixing something:
1. Close the issue with a resolution description

## Checking availability

```bash
curl -sf http://localhost:19900/api/debug/issues > /dev/null 2>&1 && echo "available" || echo "not available"
```

If not available, travel-runner may not be running or the debug-tracking module is not loaded. Fall back to reading on-disk files directly (see On-disk structure below).

## Endpoints

### GET /api/debug/issues

List issues. Optional query params:

| Param | Example | Description |
|-------|---------|-------------|
| `status` | `open`, `closed` | Filter by issue status (default: all) |
| `service_id` | `travel-portal` | Filter by originating service |
| `category` | `service_crash` | Filter by issue category |

```bash
curl -s "http://localhost:19900/api/debug/issues?status=open" | python3 -m json.tool
```

**Response shape:**

```json
[
  {
    "id": "dbg-20260510-001",
    "summary": "travel-portal crashed with SIGABRT",
    "severity": "critical",
    "status": "open",
    "service_id": "travel-portal",
    "category": "service_crash",
    "tags": ["next", "turbopack"],
    "created_at": "2026-05-10T14:32:00Z"
  }
]
```

### GET /api/debug/issues/{id}

Full issue detail including error message, recovery guidance, environment snapshot, git branches, and service states at time of capture.

```bash
curl -s http://localhost:19900/api/debug/issues/dbg-20260510-001 | python3 -m json.tool
```

**Response shape:**

```json
{
  "id": "dbg-20260510-001",
  "summary": "travel-portal crashed with SIGABRT",
  "severity": "critical",
  "status": "open",
  "service_id": "travel-portal",
  "category": "service_crash",
  "tags": ["next", "turbopack"],
  "created_at": "2026-05-10T14:32:00Z",
  "detail": {
    "error_message": "SIGABRT: process exited with code 134",
    "recovery_guidance": "Clear .next cache and restart",
    "environment": { "node": "v22.12.0", "turbopack": true },
    "git_branch": "feature/block-transfers",
    "service_states": {
      "supabase": "RUNNING",
      "travel-portal": "FAILED",
      "stripe": "RUNNING"
    }
  }
}
```

### GET /api/debug/issues/{id}/logs

Raw log text captured at the time of the error. Returns the same format as `/api/logs/{serviceId}` — an array of `{ stream, text }` entries.

```bash
curl -s http://localhost:19900/api/debug/issues/dbg-20260510-001/logs | python3 -m json.tool
```

### POST /api/debug/issues

Create a manual issue. Use for bugs that auto-capture doesn't catch (logic errors, cross-service issues, subtle regressions).

```bash
curl -s -X POST http://localhost:19900/api/debug/issues \
  -H "Content-Type: application/json" \
  -d '{
    "summary": "Guest assignment silently drops when booking has 0 capacity",
    "severity": "high",
    "service_id": "travel-portal",
    "category": "manual",
    "tags": ["guest-assignment", "capacity"],
    "detail": {
      "error_message": "assignGuest returns success but guest row not created",
      "steps_to_reproduce": "Create booking with 0 max_guests, attempt assign"
    },
    "capture_logs": true
  }'
```

**Body fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `summary` | yes | Short description of the issue |
| `severity` | yes | `critical`, `high`, `medium`, or `low` |
| `service_id` | yes | Which service is affected |
| `category` | yes | One of the categories below |
| `tags` | no | Array of freeform string tags |
| `detail` | no | Object with any additional context |
| `capture_logs` | no | If `true`, snapshots current logs for the service |

Response: `{ "id": "dbg-20260510-002", "status": "open" }`

### POST /api/debug/issues/{id}/close

Close a resolved issue. Moves the on-disk folder from `open/` to `closed/`.

```bash
curl -s -X POST http://localhost:19900/api/debug/issues/dbg-20260510-001/close \
  -H "Content-Type: application/json" \
  -d '{"resolution": "Cleared .next cache and restarted; turbopack cache corruption"}'
```

Response: `{ "id": "dbg-20260510-001", "status": "closed" }`

## Categories

| Category | Auto-captured | Description |
|----------|---------------|-------------|
| `service_crash` | yes | Process exited non-zero or received fatal signal |
| `circuit_breaker` | yes | Circuit breaker tripped after repeated failures |
| `db_setup_failure` | yes | Supabase migration or seed failure during startup |
| `preflight_failure` | yes | Preflight check failed (port conflict, missing dep) |
| `probe_timeout` | yes | Health probe exceeded timeout without response |
| `manual` | no | Manually created issue — logic bugs, cross-service problems |

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

1. `GET /api/debug/issues?status=open` — check for auto-captured issues first
2. If found, `GET /api/debug/issues/{id}` — read the detail for pre-captured context (error message, environment, service states)
3. `GET /api/debug/issues/{id}/logs` — review the captured logs
4. If no issue found, fall back to `GET /api/status` and `GET /api/logs/{serviceId}` via the travel-runner-api skill

### Recurring issue

1. `GET /api/debug/issues?service_id={service}` — list all issues (open and closed) for the service
2. Look for multiple issues with the same category or similar summaries
3. `GET /api/debug/issues/{id}` on closed issues — read prior resolutions for patterns
4. Reference the pattern in your diagnosis and note it when creating or closing the new issue

### Post-fix cleanup

1. `GET /api/debug/issues?status=open` — find the issue you just resolved
2. `POST /api/debug/issues/{id}/close` with a clear resolution description
3. Include what fixed it and why it broke — this helps with future recurring issue detection

## On-disk structure

Issues live at `~/Desktop/debug-tracking/open/` and `~/Desktop/debug-tracking/closed/`. Each issue is a folder named by its ID containing:

```
~/Desktop/debug-tracking/
  open/
    dbg-20260510-001/
      issue.json          # Full issue metadata and detail
      stdout.log          # Captured stdout at time of error
      stderr.log          # Captured stderr at time of error
      state-snapshot.json # Service states at time of capture
  closed/
    dbg-20260509-003/
      issue.json
      stdout.log
      stderr.log
      state-snapshot.json
```

If the API is not available (travel-runner not running), read the files directly:

```bash
# List open issues
ls ~/Desktop/debug-tracking/open/

# Read a specific issue
cat ~/Desktop/debug-tracking/open/dbg-20260510-001/issue.json | python3 -m json.tool

# Read captured logs
cat ~/Desktop/debug-tracking/open/dbg-20260510-001/stderr.log
```
