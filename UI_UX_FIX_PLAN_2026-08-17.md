# Travel Runner UI/UX Fix Plan — 2026-08-17

## Problem

The P5 cache-CDC work grew the service graph from 6 services to 18 (8 daemons + 10 one-shots
across 5 phases), but the UI was built for 3 phases of daemons. Result: a header row of 18
two-letter badges with massive abbreviation collisions (7× "ST", 6× "CA"), no Status-view rows
for the 12 new stream/verification services, a startup timeline blind to the new phases, and an
overflowing header (uptime string wraps mid-text).

## Fixes

### 1. Status view shows all phases — `EnvironmentSupervisor.servicesByPhase()`

- Phase list becomes `ground, gateway, portal, stream, verification`.
- Fallback switch extended with prefix matching (`stream-` → stream; `cache-`/`capacity-` → verification).
- Any service whose phase matches nothing lands in an `OTHER` group instead of being silently dropped.
- `PhaseSection` becomes collapsible (DisclosureGroup), default expanded.

### 2. Header badge row → phase summary chips — new `ServicePhaseChips.swift`

- One chip per phase: worst-status dot + label + healthy count (`n/m`).
  - red: any failed/circuit-broken · orange: any starting/stopping, or mixed pending+running
  - gray: all pending/stopped · green: all running/completed/skipped
- Click a chip → popover listing each service in the phase: status dot, name, port,
  phase text, `one-shot` tag, restart count. Clicking a row jumps to that service's
  Terminals tab (via `WorkshopNavigation.selectedLogServiceID`).
- Replaces the per-service badge row and the colliding `abbreviation(for:)` fallback entirely.
- STALE / DB Reset / uptime / restart-count tags are preserved to the right of the chips.

### 3. Startup timeline learns STREAM + VERIFY — `StartupPhase`, `resolvePhase`, `TimelineStrip`

- `StartupPhase` gains `stream = "STREAM"` and `verification = "VERIFICATION"`.
- `resolvePhase(for:)` maps graph node phases `stream`/`verification` and, instead of
  first-match-wins, returns the earliest phase in startup order present in the level
  (levels can mix gateway + stream services; earliest ordinal wins → deterministic).
- `TimelineStrip` gains STM + VER pills; pill "completed" requires the phase to be complete
  AND no longer current (multi-level phases like stream must not flip to done after level 1).

### 4. One-shots are visually distinct from daemons — `ServiceRow`

- `one-shot` capsule tag next to the name when `resolvedType == .oneshot`.
- Completed one-shots show a green checkmark instead of a bare dot.
- Completed/skipped one-shots get a re-run button (restart action; today only running/failed
  services show any action). Cascade button remains alongside.

### 5. Header polish — `WorkshopHeaderBar`

- Uptime only shown when `health == .healthy` (no "1 Failing" next to "74h24m");
  `lineLimit(1)` + `fixedSize()` so it can never wrap.
- Error banner's Retry is suppressed when the header's primary button is already Retry
  (degraded + idle) — one Retry affordance, not two.

### 6. Status view cleanup — `WorkshopStatusView`, `WorkshopView`

- Remove the redundant `ServiceDotMinimap` strip (file deleted; header chips supersede it).
- Remove the forced jump to the Status tab when ≥2 services fail (it yanks users out of
  DB Tools/Settings mid-task). Instead, the Status sidebar row gets a failure-count badge.

### 7. Terminals tab — `WorkshopLogsView`

- Tabs for completed/skipped one-shots are dimmed (secondary) so live daemons stand out.
- Selection is backed by `WorkshopNavigation.selectedLogServiceID` so chip popovers can
  deep-link into a service's console.

## Out of scope

- No changes to service topology, config schema, or the CDC pipeline itself.
- No changes to DB Tools / Issues / Diagnostics / Settings views (reviewed — they're fine).
- Existing tests (topology, config loader) don't touch the UI layer; no test changes needed.
  Verified by full build + `swift test`.

## Files touched

- `Core/EnvironmentSupervisor.swift` — servicesByPhase, StartupPhase, resolvePhase
- `Views/WorkshopHeaderBar.swift` — chips row, uptime, banner Retry
- `Views/ServicePhaseChips.swift` — NEW: chips + popover
- `Views/PhaseSection.swift` — collapsible
- `Views/ServiceRow.swift` — one-shot tag, checkmark, re-run
- `Views/TimelineStrip.swift` — new pills, pillState fix
- `Views/WorkshopStatusView.swift` — drop minimap
- `Views/WorkshopView.swift` — no focus steal, status badge
- `Views/WorkshopLogsView.swift` — dim one-shots, navigation-backed selection
- `Views/ServiceDotMinimap.swift` — DELETED

## Second pass (full read of every remaining view)

### 8. Settings giant header — `SettingsPageView.swift`

The header HStack balanced its centered title with `Color.clear.frame(width: 40)`. A bare
`Color` is fully layout-flexible, so the header greedily split the window's vertical space
with the ScrollView (~40% header, ~60% content). Fixed by pinning the spacer's height
(`frame(width: 40, height: 1)`), keeping the horizontal balance.

### 9. Duplicate Dismiss on the behind-remote banner — `WorkshopHeaderBar.swift`

The banner rendered both a "Dismiss" action button and an "×" with identical behavior.
Action removed; the "×" remains.

### Reviewed and confirmed sound (no changes)

- `WorkshopIssuesView` — filter toolbar, list/detail split, close-with-resolution flow
- `DbSetupPipelineView` / `DbSetupStepRow` — step states, progress, per-step logs, retry-from
- `DbSeedScenarioSelectorView` — scenario cards, locked-while-running, stale-selection states
- `ServiceConsoleView` — level filters, search, status bar; `TerminalTextView` — incremental
  NSTextView append with selection/drag guards
- `SetupView` / `SetupStep2View` — repo detection wizard and environment checks
- The other `Color.clear` usages are background fills (size proposed by the backed view),
  not layout participants — not greedy.
