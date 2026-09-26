# 06 - v10/v11 Fresh-Deploy Boundary

## Decision

V11 does not implement an in-place v10 migration subsystem. Stable `10.0.4`
remains the supported line for an existing v10-managed host; V11 primarily
targets a fresh VPS. A WordPress site moves to a V11 host with a reviewed
WordPress migration plugin or provider snapshot after the new host has been
validated.

This replaces the earlier design for `wp-shell migrate v10`, migration
manifests, producer-state adoption, timer compatibility handlers and migration
rollback. None of those interfaces is part of V11-A.

## Why

An in-place transition would have to reconcile service configuration, PHP
identities, cache behavior, backups, staging, historical automation and
administrator-owned files. Carrying that state machine into V11 would preserve
the control-plane complexity V11 is intended to remove. It would also create a
false impression that configuration rollback is a WordPress content/database
recovery point.

Fresh deployment is the smaller and safer boundary:

- V10 continues operating the existing host.
- V11 never stops or disables a V10 unit.
- V11 never adopts historical metrics, recommendations or tuning provenance.
- V11 never deletes a V10 database, cursor, log, unit, configuration or secret.
- V11 does not overwrite the stable `/usr/local/sbin/wp-shell` entry point.

## Detection and fail-closed behavior

Before any V11 mutating command initializes runtime paths or a transaction, it
checks for high-confidence legacy footprints:

- an existing stable `/usr/local/sbin/wp-shell` together with
  `/etc/wp-shell/environment.v1` or `/etc/wp-shell/sites.v3`;
- the recognized `/etc/wp-vps-manager` configuration tree;
- the recognized `/etc/wp-single-deploy` configuration tree;
- `/var/lib/wp-shell/metrics.sqlite3`;
- `wp-shell-metrics.service` or `wp-shell-metrics.timer` unit files.

When detected, mutation is refused with the evidence paths and the supported
next step. This is an admission guard, not a migration engine. It does not read
secret contents, execute the old entry point, call `systemctl`, create a log or
transaction, or modify any detected artifact.

Read-only `status`, `audit`, `capacity`, `dry-run` and MariaDB audit remain
available. Status/audit report the boundary so an operator can identify why V11
writes are unavailable.

Absence of these footprints is not proof that an arbitrary old installation is
safe to adopt. It only prevents the known V10 path from being silently treated
as a fresh V11 host. Administrators must not remove evidence merely to bypass
the guard; use a fresh VPS instead.

## Removed compatibility surface

V11-A has no:

- `migrate v10` command;
- `v10-metrics-migration.v1` record;
- metrics unit enabled/active-state capture or restoration;
- automatic adoption of effective pools into `tuning.v1`;
- automatic `sites.v2`/`site.v2`, database-config or Redis-secret migration;
- `legacy-vps`, `legacy-single` or `wp-single-manager` dispatcher route;
- `metrics collect` compatibility success/no-op;
- SQLite metrics schema, collector, dashboard, analyzer or automatic tuner.

Retired dashboard/report/analyze/tune/metrics names fail with concise guidance
to current-state `capacity` and explicit `site DOMAIN workers N` controls. They
never impersonate a successful background producer.

## Manual worker state

`/etc/wp-shell/tuning.v1` remains the V11 manual desired-state format for a V11
host. V11-A does not import it from V10. On a fresh V11 host, a confirmed manual
worker change writes it only after current effective pool ownership and the
host-wide hard capacity constraint pass.

## Acceptance

The regression suite proves that:

1. known V10 footprints are detected read-only;
2. read-only V11 commands remain available;
3. every V11 mutation is rejected before runtime/transaction creation;
4. V10 files, units, historical data and administrator files remain
   byte-identical;
5. no manual tuning state is synthesized or adopted;
6. `/etc/wp-vps-manager` and `/etc/wp-single-deploy` independently block all
   writes without creating `sites.v3`, database config, Redis state or a
   migration backup;
7. removal of all test-only footprints permits the fresh-deploy path;
8. no metrics producer manipulation, migration command/record, SQLite runtime,
   dashboard or automatic tuner remains.

There is deliberately no rollback procedure for V10 adoption because V11 does
not perform that adoption.
