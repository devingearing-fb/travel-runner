# Known Issues

*No open issues.*

## Resolved

### restart-cascade/supabase does not trigger db:reset on empty database

**Resolved:** 2026-05-12

**Fix:** 
- `restartCascade()` now checks `databaseHasAppTables()` after Supabase restarts and auto-triggers `db:reset` if the database is empty
- Added `POST /api/db-reset` endpoint to ControlServer for programmatic DB reset
- DB reset output now shows in a live console panel in the Services tab
