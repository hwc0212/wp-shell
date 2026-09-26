# 10 - S1 Manual Capacity Implementation

## Delivery boundary

S1 is implemented only in `wp-shell-v11.sh` and v11-specific tests/documentation. The stable root `wp-shell.sh`, immutable `legacy/wp-shell-v10.0.4.sh`, wrappers, backup/restore, Page Cache, private Redis, staging, remote backup, Cloudflare and MariaDB behavior are unchanged. The PR targets `v11`, not `main`, and remains experimental.

## Current capacity contract

`wp-shell-v11 capacity` is read-only. Its main dispatcher does not call `init_paths`, legacy config migration, package installation, self-installation or service actions. It reports:

- physical and currently available RAM;
- Swap total/used, explicitly excluded from worker capacity;
- system/page-cache, transient WP-CLI/Cron/Action Scheduler/backup/image, MariaDB planning, Redis planning and Nginx zone reserves;
- effective Redis `maxmemory` when locally readable, without printing authentication data;
- effective OPcache memory and interned-strings values for every active PHP version;
- effective distribution `[www]` and every wp-shell-managed site `pm.max_children` value from `php-fpm -tt`;
- manual desired site values from the unchanged `tuning.v1` schema;
- aggregate worker count, estimated exposure, hard budget/headroom and `SAFE`, `OVERCOMMITTED` or `UNKNOWN`.

Unknown effective OPcache/default/site pool evidence is never converted to zero or a guessed safe value.
An imported site's lifecycle remains imported, but after wp-shell has created its managed PHP pool that pool is still included in current exposure. A missing or unreadable registered pool makes current capacity `UNKNOWN`; `SITE_MODE=imported` is not used to hide worker capacity.

## Current-PSS estimator

The historical SQLite percentile estimator is removed. Each invocation starts at 96MB per process, then reads only currently running processes whose:

1. process title exactly matches a registered managed pool;
2. executable basename exactly matches that site's PHP-FPM version;
3. `/proc/PID/smaps_rollup` contains a valid positive `Pss` value.

The host estimate is `ceil(max_current_worker_PSS * 1.25)` with a 96MB floor. Current evidence may only raise, never lower, the baseline. The evidence is not persisted and a process race or unreadable `/proc` entry is discarded rather than guessed.

## Manual worker transaction

`wp-shell-v11 site DOMAIN workers N` previews the one-site replacement inside the whole-host effective aggregate and writes nothing. `--confirm` then:

1. validates the selected wp-shell-owned pool, including a pool for a registered imported site when ownership and effective semantics are proven;
2. requires its managed value and effective `ondemand` value to agree;
3. refuses unknown capacity and is separately blocked before runtime on a detected v10-managed host;
4. replaces only the selected site's current value in the prospective aggregate;
5. requires the result to fit the hard RAM-derived worker budget;
6. renders one candidate and updates the existing `tuning.v1` manual desired state in the managed transaction;
7. validates `php-fpm -t`, `php-fpm -tt`, and the full aggregate before reload;
8. reloads only the affected PHP version and only when the pool content changed;
9. repeats effective/aggregate verification after reload;
10. restores the exact prior pool and tuning file on any failure, without a success message.

An exact repeated request does not create a transaction or reload PHP. A later administrator override blocks the write and remains byte-identical.

## Conservative initial sizing

Removing historical auto-tuning does not reduce every fresh site to a
single-worker performance baseline. For sites without an explicit manual
override, V11 starts from one worker each, then deterministically targets:

- 2 ondemand workers for normal WordPress;
- 3 ondemand workers only for an explicitly selected WooCommerce site.

Automatic site concurrency stops at two worker slots per CPU and never exceeds
the aggregate hard RAM budget after default pools, current PSS estimate and all
other reserves. When the site count already exceeds that CPU target, each site
keeps only its one-worker minimum; no extra slots are assigned. Explicit manual
overrides are not silently CPU-clamped, but still must pass the whole-host hard
memory admission. Swap never raises either limit. There is no history,
recommendation loop or later automatic resizing.

## Fresh-deploy v10 boundary

V11-A deliberately has no in-place v10 metrics migration. Before any mutating
command creates runtime paths, logs or a transaction, a read-only guard checks
for a stable v10 entry point plus managed configuration, both recognized legacy
configuration trees, and known v10 metrics database/unit artifacts. Detection blocks the write and recommends
continuing stable v10 or using a fresh VPS plus a reviewed WordPress migration
plugin/provider snapshot.

The guard never executes the old script, calls `systemctl`, adopts pool values,
creates a migration record, or deletes/disables historical state. Read-only
status, audit and capacity remain available. See `06-V10-V11-MIGRATION.md`.
The V11 runtime contains no legacy config migration function, compatibility
dispatcher route, or basename-triggered single-site adoption behavior.

## Removed runtime responsibilities

- six-table SQLite schema and schema migration;
- one-minute collector, SQL batching, cursors, retention and health records;
- metrics systemd service/timer generation;
- embedded Python curses dashboard;
- historical report and resource analysis;
- automatic recommendations, pressure-history gates and `tune --apply`;
- SQLite as a clean-v11 package dependency.

The old commands return explicit deprecation errors. There is no successful
`metrics collect` compatibility no-op and no `migrate v10` command. No
replacement daemon, database, management port, framework or dependency was
added.

## Measured complexity

Measured against v11 base `40844a7e46006057721686d329acd53388f2e619`:

| Measure | v11 base | S1 implementation | Change |
|---|---:|---:|---:|
| `wp-shell-v11.sh` lines | 7,326 | 6,371 | -955 (-13.0%) |
| Runtime bytes | 349,060 | 297,196 | -51,864 (-14.9%) |
| Shell functions | 322 | 303 | -19 |
| Documented public CLI forms | 60 | 54 | -6 |
| SQLite tables owned | 6 | 0 | -6 |
| Metrics producer units created on clean install | 2 | 0 | -2 |
| Embedded curses applications | 1 | 0 | -1 |
| Embedded Python lines | 413 | 37 | -376 |
| Shell test files | 22 | 26 | +4 safety suites |
| New runtime dependencies | 0 | 0 | 0 |

Function counts include brace-bodied functions and subshell-bodied transaction
helpers. S1 replaces broad automated behavior with smaller fail-closed capacity,
manual transaction and fresh-deploy boundaries. The operational reduction—no
minute producer, SQLite state, dashboard, auto-mutation loop or migration state
machine—is more material than source size alone. Tests grow intentionally to
preserve safety evidence.

Python remains a clean-v11 dependency because retained Cloudflare CIDR/address validation and backup archive-member validation still use 37 embedded Python lines. Removing those security parsers merely to eliminate the dependency would weaken retained Core behavior and is outside S1.

## Verification map

- `tests/v11-capacity.sh`: exact conservative initial sizing across 1/2/4/8/16GB profiles, normal/WooCommerce/mixed/imported sites, CPU ceilings, zero/nonzero Swap, multiple PHP versions, aggregate overrides, current PSS upward-only and read-only/unknown/overcommit behavior.
- `tests/v11-manual-workers.sh`: preview zero-write, aggregate refusal, exact target-only change, administrator override, post-write mismatch, reload-failure rollback and idempotent no-reload.
- `tests/v11-fresh-deploy-boundary.sh`: read-only v10/legacy-footprint detection,
  pre-runtime mutation refusal, byte-identical historical/admin artifacts, no
  synthesized tuning/sites/database/Redis state, fresh-host admission and
  complete removal of in-place metrics and legacy-config migration surfaces.
- `tests/v11-fpm-integration.sh`: real Ubuntu 24.04 `php-fpm8.3 -t/-tt`, confirmed transaction and later administrator override detection.

Existing v10 test suites remain because stable v10 behavior is intentionally unchanged. No test is weakened to make v11 pass.

## Remaining risks and deliberate exclusions

- Current PSS is a conservative snapshot, not history. A cold host uses the 96MB baseline; administrators must choose limits for temporary update/image/backup spikes conservatively.
- The MariaDB reserve shown by capacity is planning information, not proof of MariaDB's actual maximum memory. `mariadb audit` remains the effective source.
- On a 1GB profile, the retained reserves may refuse even one managed site plus its distribution default pool. S1 refuses rather than silently overcommitting or treating Swap as RAM.
- A host already overcommitted across several sites cannot use sequential changes that leave an unsafe intermediate/final aggregate. S1 deliberately does not add a multi-site mutation interface.
- V10 historical data retention/deletion remains administrator-owned. V11 does
  not migrate, stop, disable or remove it; package removal is not automated.
- S2, restore/Phase 2C and all unrelated optional-feature redesigns are intentionally not started.
