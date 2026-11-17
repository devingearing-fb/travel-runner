#!/usr/bin/env bash
# Snapshot excerpt of fb-travel-monolith scripts/local-db.sh: only the part of
# build_workspace that gives the two backend bootstraps their local versions.
# The runner must count a bootstrap under the version this loop gives it.

  # Backend's replay.sh applies its two bootstraps (*_init-roles.sql, *_init-schema.sql; their
  # versions differ per environment) before everything else. Filename order alone breaks on
  # prod, whose baseline records an offline-applied file stamped before them
  # (20260909144500_customer_detail_from_checkout.sql needs fb_compete from init-schema).
  # Local-only versions sort them first; nothing here is ever pushed to a hosted project.
  local kind order=0 matches
  for kind in init-roles init-schema; do
    matches=("$WORKSPACE"/supabase/migrations/[0-9]*_"$kind".sql)
    [ ${#matches[@]} -eq 1 ] && [ -f "${matches[0]}" ] \
      || fail "backend baseline must have exactly one *_$kind.sql bootstrap"
    mv "${matches[0]}" "$WORKSPACE/supabase/migrations/0000000000000${order}_$kind.sql"
    order=$((order + 1))
  done
