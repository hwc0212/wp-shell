# 07 - Test Migration Plan

## Rule

Simplification may remove tests only when the tested product behavior is deliberately removed and no safety invariant is hidden inside the test. A failing test must not be weakened to make a deletion pass. Safety assertions are moved to the nearest surviving Core test before the old feature test disappears.

Every implementation PR is independently green. No roadmap stage relies on temporarily disabling CI or landing code and tests separately.

## Baseline

At `8dd604bea4f201a797ac7e8912a843c32c6e9c4f`:

- 21 Shell test files contain 3,323 lines.
- The normal workflow runs 16 non-container static/unit suites.
- Container integration covers Nginx, service configuration/operations, imported-site reliability, and MariaDB legacy migration on Ubuntu 22.04 and 24.04.
- `bash -n` and ShellCheck cover `wp-shell.sh`, both wrappers, and every test.
- The exact baseline commit is green on the current GitHub workflow.

This is the behavior reference, not evidence that every v11 behavior should remain.

## Existing test disposition

| Test | v11 disposition | Required migration |
|---|---|---|
| `tests/static-checks.sh` | KEEP/ADAPT | Keep strict mode, trap, temp-file, quoting, secret and unsafe-write guards. Remove references only after corresponding code is gone. Add a docs/runtime scope guard while staged deletion is underway. |
| `tests/config-roundtrip.sh` | KEEP/ADAPT | Preserve all v10 reader/round-trip cases and unknown fields. Add v10 preflight/confirmed migration/idempotency/corruption fixtures. |
| `tests/render-nginx.sh` | KEEP/ADAPT | Retain default-host 444, static delivery, PHP `try_files`, uploads execution block, protected paths, safe headers, FastCGI transport, Page Cache Lite render/bypass and optional CF real IP. |
| `tests/storage-layout.sh` | KEEP/ADAPT | Keep `/etc/wp-shell`, `/var/lib/wp-shell`, site-root, permissions and path ownership checks. Assert v11 creates no metrics/operations state on a clean install. |
| `tests/metrics-roundtrip.sh` | REMOVE after S1 migration coverage | Before removal, extract worker-estimate safety cases to capacity tests and add preservation/disablement tests for the old database/timer. |
| `tests/wordpress-core.sh` | KEEP/ADAPT | Keep WordPress download/checksum, safe config writes, permissions, constants and Cron semantics. Remove bulk upgrade/plugin-specific paths only with explicit negative tests. |
| `tests/dashboard-smoke.sh` | REMOVE in S1 | No Core behavior should depend on terminal rendering. Add CLI status/capacity output smoke coverage first. |
| `tests/menu-routing.sh` | ADAPT | Replace dashboard/tuner/removed menu choices with the smaller CLI/menu contract; keep installed/uninstalled/import branching and numeric-selector compatibility. |
| `tests/opcache-config.sh` | ADAPT in S2 | Preserve conservative install baseline, effective per-version reserve and administrator override detection. Delete auto-tune/UI mutation expectations. |
| `tests/php-memory-budget.sh` | KEEP/EXPAND | Retain every Phase 2B hard invariant, effective-default/site pool check, aggregate override, imported-site gate, no-write failure and rollback case. Replace historic PSS fixtures with current-PSS upward-only fixtures. |
| `tests/mariadb-legacy.sh` | KEEP | Preserve read-only effective audit, true legacy/current-managed distinction, risk gate, explicit migration, idempotency and exact rollback fixtures. |
| `tests/imported-site-reliability.sh` | KEEP | Preserve PHP detection/fallback, in-memory admission before persistence, write window, symlink/path protection, fail-closed debug probe, final permissions and backup-age regression. |
| `tests/reliability-regression.sh` | KEEP/ADAPT | Keep transaction, atomic replace, signal/error, permission, backup completeness and no-secret regressions. Remove feature-specific assertions only after equivalent Core/compatibility assertions exist. |
| `tests/control-plane.sh` | KEEP/ADAPT | Narrow apply/dry-run/audit/rollback ownership; retain admission-before-write, candidate failure, fingerprint conflict and reload-only-if-changed behavior. |
| `tests/cloudflare-policy.sh` | KEEP/NARROW | Retain official CIDR validation, atomic update/fallback, trusted-header and forged-header checks. Remove any future API/cache behavior rather than expanding it. |
| `tests/compatibility-policies.sh` | KEEP/EXPAND | Become the main v10 compatibility/migration fixture set: wrappers, unknown keys, deprecated units, private Redis, legacy cache-auto/custom cache rules, remote backup and staging blockers. |
| `tests/nginx-integration.sh` | KEEP/ADAPT | Continue real Nginx syntax/routes/TLS/static/protected/PHP-404 checks. Keep permanent Page Cache Lite anonymous HIT and bypass coverage plus legacy/custom preservation fixtures. |
| `tests/service-config-integration.sh` | KEEP/ADAPT | Retain effective PHP pool, MariaDB/Redis loopback, config transaction and rollback checks. Remove metrics/private Redis creation from clean-v11 expectations. |
| `tests/operations-integration.sh` | SPLIT/RETIRE in S2 | Move local backup/restore/Cron assertions to Core operations integration. Retain compatibility-handler cases until old operations/cache timers are migrated, then remove cache/staging/update paths. |
| `tests/imported-site-integration.sh` | KEEP | Continue the Ubuntu 24.04 real-filesystem import reliability path; add v10-policy compatibility fixture where needed. |
| `tests/mariadb-legacy-integration.sh` | KEEP | Continue Ubuntu 22.04/24.04 effective-value, migration, restart failure/rollback and administrator-file preservation coverage. |

## S1 mandatory regression additions

S1 removes metrics/dashboard/automatic tuning. Before that deletion lands, tests must prove:

### Capacity without historical SQLite

- Empty/no metrics database uses the conservative worker baseline.
- A valid current managed-pool PSS observation plus safety margin can raise but never lower that baseline.
- Stale, zero, negative, malformed, unowned or incomplete current PSS evidence is ignored and cannot make an unsafe request pass.
- Multiple process samples use a robust high estimate, not a simple average; a brief low-idle reading cannot expand capacity.
- Effective OPcache for every active PHP version is reserved separately.
- Effective default and all managed pools are included.
- Swap never increases resident worker capacity.
- Unknown/mismatched effective pools block mutation.

### Manual workers and hard admission

- A new low-traffic site may receive one ondemand worker.
- Aggregate manual overrides are validated together, including values that are individually valid but collectively exceed budget.
- Imported sites run admission before `sites.v3`, credentials, policy, users, pools, Nginx or service writes.
- `site DOMAIN workers N --confirm` fails before pool writes/reload when unsafe.
- A successful operation satisfies the aggregate exposure invariant before and after effective reload verification.
- Post-write effective mismatch rolls back and never reports success.
- Repeating the same safe worker request is a no-op and does not reload PHP.

### Pressure and safety vetoes

- Current OOM evidence, growing/active Swap, meaningful memory PSI, severe I/O pressure or unsafe MariaDB effective state vetoes expansion.
- Missing pressure files are reported as unknown/conservative, not converted to zero pressure.
- A shrink can remain admissible when expansion is vetoed, provided effective state and transaction safety are known.

### Retired feature migration

- Unconfirmed `migrate v10` is read-only.
- Confirmed migration disables the exact metrics producer, retains the SQLite database/logs/units, and records previous unit state.
- Retired timer entry-point compatibility writes no samples and does not claim success data.
- Dashboard/analyze/tuner commands return explicit deprecation output without state mutation.
- Existing `/etc/wp-shell/tuning.v1` values remain the manual desired state.
- Migration is idempotent and rollback restores exact prior unit state.

## Restore test migration

Restore is unchanged during S1-S3. S4 adds the conservative contract in an isolated PR.

Required S4 tests:

1. requested backup checksum, manifest/domain and archive-member validation;
2. compressed SQL validation and disposable restricted-database restore test;
3. insufficient disk and interrupted safety-backup refusal before maintenance/data writes;
4. exact verified safety-backup ID printed and persisted in a root-only failure receipt;
5. maintenance entry is verified before file/database mutation;
6. failure injection before files, after files, after database and during permission/verification steps;
7. every injected failure leaves maintenance enabled, preserves both backups and prints the exact `--recover --confirm` command;
8. recovery restores from the named safety backup, not “latest,” and requires explicit confirmation;
9. success exits maintenance and clears only the matching receipt;
10. paths/symlinks, permissions, credentials, low disk, incomplete archives and secret redaction remain protected;
11. a second successful restore/recovery is deterministic and leaves no false active state;
12. no test claims Shell-level atomicity across files and MariaDB.

Tests for the unmerged Phase 2C journal/state machine are not imported wholesale. They are useful failure-injection scenarios, but the persistent multi-state interface is not the chosen design.

## v10-to-v11 migration tests

Use fixture matrices, not the developer's live host:

| Fixture | Expected outcome |
|---|---|
| Clean v10 Core-only configuration | Preflight `CLEAN`/`COMPATIBLE`; confirmed migration succeeds and repeats as no-op |
| Metrics timer and populated SQLite DB | Timer disabled only with confirmation; database/unit files retained; rollback restores unit state |
| Automatic tuning history plus current manual limits | History retained inactive; desired limits preserved; aggregate capacity revalidated |
| Existing generic page-cache site | Enabled/disabled state adopted as Page Cache Lite; effective HIT/bypass behavior verified; cache data retained |
| Existing custom cache rules or cache-auto | Custom includes and MU plugin/data retained; affected apply preserves behavior or blocks; timer disablement is explicit and reversible |
| Existing private Redis site | Instance/config/secret retained; no fallback to shared Redis; affected apply blocked if preservation cannot be proven |
| Existing remote backup as only off-host copy | `EXTERNAL_REPLACEMENT_REQUIRED`; timer/upload not silently disabled |
| Existing staging route | Route/root/data retained and reported; no production conversion |
| Unknown policy key/admin config | Byte-for-byte retained |
| Corrupt site/config/migration manifest | Read-only status reports conflict; confirmed mutation refuses |
| Deprecated wrapper caller | Arguments forwarded, warning emitted, same safe implementation reached |
| Post-plan administrator edit | Fingerprint conflict refuses overwrite/rollback |
| Low disk during migration backup | Failure before live writes/unit changes |

## CI shape by stage

### Page Cache Lite permanent coverage

- FastCGI transport uses the selected site's Unix socket and required parameters/timeouts/buffers.
- A nonexistent PHP script returns 404 before FastCGI execution.
- Page Cache Lite defaults off and repeated status/apply does not enable it.
- Explicit enable, disable and manual clear are transactional and idempotent.
- Anonymous generic WordPress `GET`/`HEAD` requests can reach HIT.
- POST, authorization, query-string, admin, login, Cron, REST, XML-RPC, feed, sitemap, preview and WordPress authenticated/password/commenter state bypass cache.
- WooCommerce cart/checkout/account/API paths and session/cart cookies bypass only when WooCommerce is an explicit site property.
- A normal WordPress site does not gain plugin/theme/RFQ/Pretty Links-specific assumptions.
- Manual clear cannot escape the selected validated cache root, follow a symlink, flush Redis/OPcache or purge Cloudflare.
- No Page Cache Lite action installs an MU plugin, starts an invalidation timer, writes metrics or performs automatic tuning.
- Existing custom exclusions remain byte-identical or the affected apply fails before Nginx writes/reload.

### Required for every PR

- `bash -n` on runtime, wrappers and all Shell tests;
- ShellCheck on runtime, wrappers and all Shell tests;
- all surviving static/unit suites;
- assertions that only files in the PR's stated ownership scope changed;
- secret-pattern and generated-artifact checks.

### Container coverage

- Keep Ubuntu 24.04 Nginx and service integrations.
- Keep MariaDB legacy integration on Ubuntu 22.04 and 24.04.
- Add a smaller Ubuntu 22.04 Core smoke path before declaring v11 compatible, because MariaDB-only coverage is not full-host compatibility.
- Exercise both x86_64 CI and an available aarch64-compatible environment before v11 GA; if native hosted aarch64 is unavailable, record that gap rather than treating emulation as complete production proof.

### Matrix that must remain for PHP capacity

At minimum model 1GB, 2GB, 4GB, 8GB and 16GB physical RAM with:

- zero and nonzero Swap (same capacity result);
- single normal and WooCommerce sites;
- multiple normal, multiple WooCommerce and mixed sites;
- multiple PHP versions and their OPcache reserves;
- legacy imported site counts;
- aggregate manual overrides;
- current-PSS evidence and pressure vetoes.

Any case returning success must satisfy the aggregate hard budget invariant. Insufficient configurations make no pool/config/service changes.

## Tests that must not be lost with features

- safe temp directories, strict quoting and error/signal traps;
- render -> validate -> backup -> atomic replace -> effective verify -> rollback;
- reload only when a validated effective change requires it;
- exact fingerprint protection against overwriting administrator edits;
- no secret leakage in stdout/stderr/logs/backups/test traces;
- path traversal and symlink refusal;
- per-site FPM isolation and final WordPress permissions;
- unknown/corrupt state fails closed;
- MariaDB legacy safety and administrator ownership;
- disk-headroom and incomplete-backup protection;
- idempotency of install, apply, migration, workers, backup scheduling and rollback.

## Acceptance rule for deleting a test file

A feature test can be deleted only when the implementation PR documents:

1. the product behavior intentionally removed;
2. every safety assertion extracted to a surviving test, with exact test names;
3. compatibility behavior for existing v10 state;
4. negative proof that a clean v11 install no longer creates the old state/dependency/unit;
5. green static, unit and integration checks before and after deletion.

Test-line reduction is not a simplification success metric. Stronger Core tests may keep the total test suite near its current size even while runtime and operational state shrink substantially.
