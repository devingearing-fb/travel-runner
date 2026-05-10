---
name: api-change-protocol
description: Cross-repo update protocol for travel-runner API changes. Ensures the API skill, the booking-portal consumer skill, and the bug-report schema stay in sync when ControlServer endpoints change.
trigger: when modifying ControlServer.swift, adding or removing API routes, changing response shapes, or adding new service IDs in travel-runner
---

# API Change Protocol

The travel-runner control API is documented in three places that must stay in sync:

| Location | Role | Path |
|----------|------|------|
| **travel-runner API skill** | Source of truth | `travel-runner/.claude/skills/travel-runner-api/SKILL.md` |
| **booking-portal consumer skill** | Downstream copy for portal agents | `travel-booking-portal/.claude/skills/travel-runner-control/skill.md` |
| **bug-report schema** | References API response shapes | `fb-travel-data/claude-issues/README.md` |

## When this applies

Any time you make a change that affects the external contract:

- Adding, removing, or renaming an endpoint in `ControlServer.swift`
- Changing the response JSON shape from any endpoint
- Adding a new service ID to the config schema or `ServiceGraph`
- Changing health status values or service phase names
- Modifying the log entry format (stream/text structure, pino fields)

This does NOT apply to internal-only changes (refactoring ControlServer internals, changing how actions are dispatched, performance improvements with no external effect).

## Update checklist

Copy and execute in order:

```md
API change sync:
- [ ] 1) Make the code change in ControlServer.swift (or related files)
- [ ] 2) Update travel-runner/.claude/skills/travel-runner-api/SKILL.md
       - Endpoint table, response shapes, service ID table, diagnostic workflows
- [ ] 3) Update travel-booking-portal/.claude/skills/travel-runner-control/skill.md
       - Mirror the endpoint changes in the "Available Commands" section
       - Update the "Service IDs" table if IDs changed
       - Update the "When to use" section if new endpoints enable new workflows
- [ ] 4) If response shapes changed: update fb-travel-data/claude-issues/README.md
       - The "environment" field references service IDs and phases
       - The "error_output" field examples should reflect actual log format
- [ ] 5) Verify consistency: the three files should agree on endpoints, service IDs, and response shapes
```

## What to check in each file

### travel-runner-api SKILL.md (source of truth)

This is the canonical reference. Every endpoint must have:
- Method and path
- Parameters (query params, path params)
- Response JSON shape with example
- Behavioral notes (async vs sync, side effects)

### booking-portal skill.md (consumer copy)

This is a practical quick-reference for agents working in the portal. It should have:
- curl examples for every endpoint
- The service ID table (must match source of truth)
- "When to use" patterns matching current capabilities
- Bug reporting instructions (bottom section)

### fb-travel-data bug-report schema

The `environment.service` field enum and severity definitions should reflect current service IDs and failure modes. If you add a new service, add it to the valid `service_id` values.

## Common mistakes

- Updating the code but not the skills (consumers silently break)
- Updating one skill but not the other (divergence)
- Adding a new endpoint to the source-of-truth skill but forgetting to add a curl example to the consumer skill
- Changing a service ID without updating the service ID table in both skills
