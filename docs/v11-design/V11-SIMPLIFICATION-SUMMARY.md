# wp-shell v11 Simplification Summary

Status: design proposal only. No v11 runtime implementation is included in this branch.

## Baseline

- Frozen functional reference: `wp-shell 10.0.4`
- Exact `main` commit inspected: `8dd604bea4f201a797ac7e8912a843c32c6e9c4f`
- Main runtime: `wp-shell.sh`, 7,303 lines and 347,861 bytes
- Compatibility wrappers: 34 lines and 940 bytes combined
- Functions in the main runtime: 320, including subshell-style functions
- Public command forms documented by `show_help()`: 60, before counting every action variant and internal timer entry point
- Tests: 21 Shell test files, 3,323 lines and 144,267 bytes
- README: 1,848 lines and 91,094 bytes
- Generated background units: eight fixed service/timer unit files, plus one service for every private Redis instance; optional per-site and AIDE Cron files are additional schedules

Baseline validation completed before creating these documents:

- `bash -n` passed for the runtime, both wrappers, and all tests.
- ShellCheck 0.9.0 passed for the runtime, both wrappers, and all tests.
- All 16 non-container tests used by the current workflow passed locally.
- The exact baseline commit has successful GitHub checks for the main test job and MariaDB legacy integration on Ubuntu 22.04 and 24.04.
- The working tree remained clean throughout baseline inspection.

## Stable and development line policy

The reviewed `10.0.4` release is the frozen stable/LTS baseline. During v11 development:

```text
main                         stable v10 line; wp-shell.sh remains the public entry point
v10-maintenance              critical v10 fixes only
legacy/wp-shell-v10.0.4.sh   immutable snapshot matching tag v10.0.4
v11                          simplified development branch
wp-shell-v11.sh              experimental v11 artifact, not production GA
```

v11 is derived from the proven v10 source rather than rewritten. It is invoked as `./wp-shell-v11.sh` on disposable/test systems and, if explicitly installed for development, uses `/usr/local/sbin/wp-shell-v11`. It must not replace `/usr/local/sbin/wp-shell`, redirect the root script, change existing raw-main URLs, or publish a v11 Release before GA.

The two versions do not create parallel configuration control planes by default. `/etc/wp-shell`, `/var/lib/wp-shell`, systemd units, Nginx/PHP/MariaDB/Redis files and site backup roots can still collide if the experimental script is deliberately run mutating commands on a v10 host. The bootstrap therefore requires an explicit development mutation opt-in and prominently limits use to disposable/test systems; a later migration design must own production transition.

## Decision

v11 should remain a single-executable WordPress VPS installer and basic operations tool. It should not continue growing as a local monitoring platform, automatic performance optimizer, plugin-aware cache orchestrator, staging manager, remote-backup platform, or generic Linux control panel.

The simplification should remove responsibilities before considering source modularization. Moving unchanged functions into more files would add a build and distribution problem without reducing operational complexity.

## v11 Core boundary

The proposed Core contains:

- Ubuntu 22.04/24.04 and architecture admission checks.
- Installation of the minimum Nginx, PHP-FPM, MariaDB, shared local Redis, Certbot, Fail2ban, UFW, logrotate, and WP-CLI baseline.
- Site list, add, import, deploy/repair, status, and explicit PHP worker configuration.
- A separate non-root PHP identity, pool, socket, status socket, and private filesystem group for every managed site.
- The safe `wp-config.php` write window and final `0640 root:<site-group>` ownership model.
- Read-only audit/status/capacity output.
- Confirmed, transactional managed-configuration apply and fingerprint-protected rollback.
- Effective PHP-FPM semantic checks and a hard aggregate PHP worker memory gate.
- Read-only effective MariaDB auditing and explicit legacy migration.
- Local backup, checksum verification, deep disposable-database verification, backup-all, and a conservative restore contract.
- Optional system WP-Cron if it remains a small, non-duplicating Cron entry.
- Optional per-site FastCGI Page Cache Lite, default off, with explicit enable/disable/manual clear, one generic WordPress bypass set, and a WooCommerce bypass extension only when WooCommerce is an explicit site property.
- Optional Cloudflare real-IP trust only: verified official CIDRs, trusted-header correctness, and no Cloudflare API or cache policy.
- Minimal, compatibility-first security controls that do not assume a theme, plugin, CDN, or WooCommerce installation.

## Largest removals or externalizations

1. SQLite historical metrics, one-minute collection, cursor state, historical reports, and retention.
2. The embedded Python/curses terminal dashboard.
3. Automatic PHP tuning, historical recommendation files, sample gates, and automatic expansion logic.
4. OPcache tuning UI and mutation workflow; capacity retains only effective OPcache accounting and a conservative install baseline.
5. Per-site private Redis services, sockets, credentials, migration workflow, and private Redis metrics.
6. FastCGI cache orchestration: automatic invalidation MU plugin, cache event timer, arbitrary route-exclusion CLI, plugin/theme intelligence, historical cache metrics, and automatic cache tuning. The small Page Cache Lite capability remains Core.
7. Staging orchestration and Action Scheduler-specific inspection.
8. Remote encrypted backup orchestration; standard external tools should own off-host retention.
9. WordPress core/plugin/theme bulk-update orchestration.
10. AIDE, Postfix, and unattended-upgrades management commands; these are standard host-administration concerns and should be documented, not reimplemented as wp-shell product features.

Existing v10 configuration must not be deleted or silently neutralized. Some removed features need one-major-version compatibility readers or an explicit migration gate.

## Safety features that remain non-negotiable

- Host survival takes priority over a minimum worker count or performance convenience.
- Swap is reported as emergency protection and pressure evidence, never added to resident capacity.
- A successful worker/apply operation must not generate an aggregate estimated FPM exposure above the hard PHP worker budget.
- Every relevant current default and site pool is read from effective `php-fpm -tt` output; managed-file contents alone are not proof.
- Unknown or conflicting effective configuration fails closed before service changes.
- MariaDB legacy risk detection and administrator-file preservation remain.
- Candidate render, validation, backup, atomic replace, service validation, reload-if-needed, and rollback remain the managed-config write path.
- WordPress path, symlink, non-root execution, permissions, secret-redaction, and imported-site fixes remain.
- Backup checksums, archive safety, disk headroom, database dump validation, and restore-before-change protection remain.

## PHP capacity after metrics removal

The metrics database currently contributes only one safety-relevant behavior that must be replaced deliberately: `php_worker_memory_estimate()` can raise the 96MB baseline using valid per-worker PSS p95 history plus 25%.

The v11 replacement should:

- Start from a documented conservative compatibility baseline, never a lower measured value.
- Read current PSS from running managed pools and allow that observation only to raise the estimate with a safety margin.
- Read effective OPcache per active PHP version and reserve it separately.
- Include every effective default pool and managed site pool in aggregate exposure.
- Keep non-FPM transient reserves for WP-CLI, Cron, backups, updates, and image processing.
- Refuse expansion when effective pool data, memory pressure, MariaDB safety, or the final aggregate is unknown/unsafe.
- Never recommend or automatically increase workers.
- Treat `site DOMAIN workers N` as an explicit operator request and validate the whole host, not the selected pool alone.

The existing `/etc/wp-shell/tuning.v1` format should be retained in v11 as the manual desired-worker state. Reusing it avoids a risky format migration; only the automatic producer is removed.

## Restore recommendation

Use the conservative design, not the persistent Phase 2C state machine:

1. Validate the requested backup, including checksum, manifest/domain, archive members, compressed SQL, disk headroom, and a disposable restricted-database restore test.
2. Create and verify a local safety backup of the current site and print its exact ID.
3. Enter and verify fail-closed maintenance.
4. Restore files, then database, then permissions and managed connection settings.
5. Verify WordPress with non-mutating checks.
6. On success, exit maintenance and clear the small failure receipt.
7. On failure, keep maintenance enabled, keep both backups, record the failed step in a root-only receipt, and print the exact confirmed command for restoring the safety backup.

This is intentionally not Shell-level ACID across the filesystem and MariaDB. It removes the most dangerous behavior in 10.0.4—partial restore without an actionable recovery pointer—without adding the 600-plus runtime lines and multi-state recovery surface of the proposed Phase 2C branch.

## Migration principles

- Treat 10.0.4 as the frozen/LTS behavioral reference.
- Require a read-only v10 preflight before v11 makes managed changes.
- Never delete optional v10 files, units, databases, policies, private Redis instances, remote backup settings, or custom Nginx includes automatically.
- Preserve current site routing and cache behavior during the transition. Existing generic v10 page-cache state can be adopted by Page Cache Lite; custom/plugin-specific exclusions remain administrator-owned and are never discarded.
- Disable a retired background task only in an explicit confirmed migration, and leave its unit/config/data for manual retention or later removal.
- Block upgrade completion when removing behavior would silently stop off-host backups or alter public page-cache semantics.
- Keep both compatibility wrappers for v11, emit deprecation warnings, and remove them no earlier than v12.

## Estimated outcome

After S1-S5, the realistic target is approximately 4,200-4,800 lines and 205-245KB for the main runtime: about 34-42% fewer runtime lines and roughly 30-41% fewer bytes. Retaining Page Cache Lite deliberately raises the target from the earlier estimate. This is not a line-count quota. The more important reductions are:

- mandatory wp-shell background units: from six installed during normal use (backup, metrics, and their services/timers) plus optional units, to zero mandatory units; at most the optional Cloudflare real-IP updater remains two units;
- historical SQLite tables: six to zero;
- normal operator command forms: from 60 documented forms to roughly 18 Core forms plus a small compatibility/advanced surface;
- mutable derived state: metrics DB/cursors/recommendations removed;
- hidden automation: automatic tuning, cache event processing, remote upload, staging mutation, and bulk WordPress updates removed. Page Cache Lite has no background invalidation process.

## Recommended S1

S1 should remove historical monitoring, dashboard, and automatic tuner only. It must also add the manual `capacity` and worker-setting contracts before removing metrics, preserve `/etc/wp-shell/tuning.v1` as manual state, explicitly migrate/disable the metrics timer without deleting units or data, and retain every existing PHP admission/effective-FPM/import/transaction regression that does not depend on historical monitoring.

S1 must not change restore, private Redis, page cache, staging, remote backup, Cloudflare trust, README structure, or source packaging. Those decisions belong to later independent PRs.

## Documents

- `01-CURRENT-SCOPE-INVENTORY.md`: evidence-backed current architecture and restore comparison.
- `02-KEEP-REMOVE-MATRIX.md`: command and feature decisions.
- `03-CLI-CONTRACT.md`: proposed Core CLI and behavior.
- `04-STATE-AND-CONFIG-MAP.md`: all `/etc/wp-shell` and `/var/lib/wp-shell` state classes.
- `05-DEPENDENCY-MAP.md`: feature/data/service coupling.
- `06-V10-V11-MIGRATION.md`: preservation and explicit migration rules.
- `07-TEST-MIGRATION-PLAN.md`: test-by-test disposition.
- `08-IMPLEMENTATION-ROADMAP.md`: small PR sequence S1-S6.
- `09-SIMPLIFICATION-SCORECARD.md`: measured baseline and target estimates.
