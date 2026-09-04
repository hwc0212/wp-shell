# 01 - Current Scope Inventory

## Purpose and evidence boundary

This document describes the actual `main` implementation at commit `8dd604bea4f201a797ac7e8912a843c32c6e9c4f`, version `10.0.4`. It is not an inventory of PR #5, an older README promise, or a desired v11 implementation.

The inspection covered:

- all 7,303 lines of `wp-shell.sh` by function and responsibility range;
- the complete command routers and help output;
- both 17-line compatibility wrappers;
- all 21 test files and the GitHub Actions workflow;
- every persistent state root referenced under `/etc/wp-shell` and `/var/lib/wp-shell`;
- generated Nginx, PHP-FPM, MariaDB, Redis, systemd, Cron, logrotate, Certbot, Fail2ban, SSH, UFW, AIDE, and Postfix paths;
- the current backup and restore execution paths;
- the unmerged Phase 2C PR only for the required restore-design comparison.

## Measured repository baseline

| Item | Current value | Measurement method |
|---|---:|---|
| Main runtime | 7,303 lines / 347,861 bytes | `wc -l -c wp-shell.sh` |
| Compatibility wrappers | 34 lines / 940 bytes | `wc -l -c` on both wrappers |
| Main runtime functions | 320 | function definitions using `{` or subshell `(` bodies |
| Public help command forms | 60 | `sudo wp-shell ...` lines in `show_help()` |
| Test files | 21 | `tests/*.sh` |
| Test code | 3,323 lines / 144,267 bytes | `wc -l -c tests/*.sh` |
| Workflow | 119 lines / 4,149 bytes | `.github/workflows/shellcheck.yml` |
| README | 1,848 lines / 91,094 bytes | `wc -l -c README.md` |
| Tracked files | 27 | `git ls-files` |

Baseline results:

- syntax passed for all Shell files;
- ShellCheck passed for the runtime, wrappers, and all tests;
- all 16 non-container tests in the workflow passed locally;
- GitHub reports success at this exact commit for the main workflow job and MariaDB legacy jobs on Ubuntu 22.04 and 24.04.

## Actual runtime architecture

The single executable is organized implicitly by function ranges rather than separate modules.

| Area | Principal functions / approximate range | Current responsibilities |
|---|---|---|
| Process safety and transactions | lines 1-429 | strict mode, logging, root escalation, safe temporary paths, managed-path admission, file backup, atomic writes, service markers, fingerprints, automatic/manual rollback |
| Configuration/state loaders | lines 430-1,127 | environment v1, sites v3, tuning v1, OPcache v1, legacy multi/single config migration |
| PHP capacity and FPM | lines 1,128-1,757 | RAM/swap model, historical PSS estimator, aggregate allocation, default/site effective pool parsing, pool and PHP INI rendering, per-site identity migration |
| MariaDB | lines 1,758-2,247 | definition discovery, runtime/effective audit, low-memory risk gate, legacy migration, conservative managed baseline, restart/health/rollback |
| Redis | lines 2,248-2,618 | shared secret lifecycle, log redaction, shared server config, per-site private Redis service and WordPress connection mutation |
| Cloudflare and host baseline | lines 2,619-2,910 | official CIDR fetch/validation, Nginx real-IP config, updater timer, trusted-header check, Fail2ban, UFW, logrotate, Certbot hook |
| Nginx and TLS | lines 2,911-3,304 | global log/security primitives, unknown-Host default, candidate validation, site install/rollback, ACME, certificate issuance, HTTPS/security/cache template |
| WordPress identity/lifecycle | lines 3,305-4,117 | layout, legacy backup copy, path/symlink checks, safe WP-CLI wrappers, `wp-config.php` write windows, permissions, strict core verification/repair, installation/deploy, credentials summary |
| Backup and application operations | lines 4,118-4,941 | local/remote backup, checksums, disposable DB drill, restore, cache clearing, bulk WordPress updates, system WP-Cron, cache event processing, staging, policy actions |
| Metrics/dashboard/tuner | lines 4,942-6,095 | six SQLite tables, per-minute probes, cursor state, retention, report, 380-line Python/curses dashboard, pressure vetoes, recommendations, tuning apply/rollback |
| Import, host operations, control plane | lines 6,096-6,780 | site import/PHP detection/admission, host audit, queues, SSH/UFW/AIDE/mail/update actions, status/audit/plan/apply/rollback/security scan |
| Menus, compatibility, CLI routing | lines 6,781-7,303 | new-host wizard, environment detection, adoption/transfer, 18-option menu, help, top-level aliases, wrapper routing, read-only vs mutating initialization |

## Primary execution paths

### Read-only control plane

`main()` routes `audit`, `status`, and `dry-run` without `init_runtime()` or legacy migration. It loads existing state only, then calls:

```text
audit -> control_plane_audit
      -> validate_managed_stack
      -> system_audit
      -> mariadb_audit
      -> php_capacity_status_report
      -> per-site permissions/TLS/backup/queue/policy checks

status -> control_plane_status

dry-run apply -> control_plane_plan
```

This read-only distinction is a Core safety contract and should remain.

### Confirmed configuration apply

```text
apply --confirm
  -> control_plane_plan
  -> calculate_resource_budget (hard admission before service changes)
  -> configure_mariadb
  -> configure_redis
  -> configure_php
  -> configure_fail2ban
  -> configure_log_rotation
  -> install_certbot_deploy_hook
  -> install_nginx_log_format/default host
  -> configure_https_site for every eligible managed site
  -> apply_wordpress_baseline
  -> validate_managed_stack
  -> nginx reload
  -> transaction_commit in main
```

This path currently spans both Core infrastructure and optional application policy. v11 should narrow what apply owns, not remove its transaction discipline.

### Site add and deploy

```text
site add
  -> collect_site_input
  -> add site to in-memory state
  -> global PHP admission
  -> persist sites.v3 and cache policies
  -> create per-site Unix identity
  -> prepare_stack
  -> deploy_site
  -> metrics timer + immediate sample

site deploy
  -> prepare_stack
  -> deploy_site
     -> directories/database
     -> ACME/certificate
     -> HTTPS Nginx policy
     -> WordPress install/baseline/plugins
     -> cache clear
     -> persist managed mode
  -> metrics timer
```

The compulsory metrics activation is outside the proposed v11 product boundary.

### Imported-site lifecycle

The current importer:

1. scans `/var/www` and `/home` for real `wp-config.php` files;
2. checks WordPress core presence and a non-privileged readable owner;
3. reads the home URL with plugins/themes skipped;
4. derives domain and finds PHP from matching Nginx config;
5. falls back to `DEFAULT_PHP_VERSION` only when detection is invalid;
6. appends discovered sites only to in-memory arrays;
7. runs global PHP capacity admission;
8. only then writes `sites.v3` and per-site user policy.

This ordering, along with the safe `wp-config.php` write window used during later deployment, must remain.

### PHP capacity

Current admission computes:

```text
physical RAM
- system/page-cache reserve
- transient PHP/backup reserve
- MariaDB planning reserve
- Redis budget
- 16MB per-site FastCGI key zone
- effective/desired OPcache per active PHP version
= hard PHP worker budget, capped at 35% of RAM
```

It then:

- starts from 96MB per worker;
- may raise the estimate using 1,000+ valid PSS samples spanning at least 24 hours, p95 plus 25%;
- counts one effective/minimum default pool worker per active PHP version;
- gives every site at least one worker;
- validates all manual overrides together;
- distributes remaining slots by normal/WooCommerce weighting;
- refuses if the aggregate estimated worker allocation exceeds the budget;
- never treats Swap as resident capacity.

`php-fpm -tt` is separately parsed to prove effective default and site pool limits before reload and for current-capacity/tuning decisions.

### MariaDB safety

Current code discovers relevant definitions in:

- `/etc/mysql/my.cnf`;
- `/etc/mysql/conf.d/*.cnf`;
- `/etc/mysql/mariadb.conf.d/*.cnf`.

It distinguishes legacy `50-wordpress.cnf`, current managed `60-wp-shell.cnf`, and administrator/distribution files. `mariadb audit` reports runtime values, next-start effective values, status counters, definitions, likely source, and conservative low-memory risk signals. Normal apply blocks when effective state is unknown or unsafe. Explicit migration changes only recognized legacy files and individually unsafe managed definitions, validates, restarts only when effective values change, verifies runtime health, and rolls back exact files on failure.

### Configuration transaction

The transaction layer covers managed configuration files and service reload/restart recovery. It does not claim to roll back WordPress database or content mutations.

```text
write intent
 -> safe target check
 -> transaction start
 -> exact file/symlink backup
 -> candidate in target directory
 -> atomic move
 -> syntax/effective validation in feature code
 -> reload/restart only when needed
 -> record post-commit fingerprints
```

Manual rollback refuses to overwrite a file whose post-commit fingerprint has changed.

## Current policy surface

Per-site policy files control at least:

- runtime user;
- page cache;
- object cache;
- shared/private Redis mode, private memory, and private secret;
- automatic page-cache invalidation;
- cache exclusions through generated custom Nginx files;
- login limiting;
- HSTS;
- XML-RPC;
- response-header profile;
- system/request WP-Cron and prior state;
- staging path, URL, and Redis prefix;
- encrypted remote backup target.

Host policy controls Cloudflare mode, Redis maxmemory override, and confirmed external-mail mode. This policy breadth is a major source of cross-feature branching in apply, status, audit, security scan, Nginx rendering, WordPress deployment, backups, and menus.

## Current background work

| Unit/schedule | Trigger | Action | Installed when |
|---|---|---|---|
| `wp-shell-metrics.timer/service` | every minute | collect SQLite metrics | server bootstrap, site add/deploy, monitoring adoption |
| `wp-shell-backup.timer/service` | daily around 02:00 | `backup-all` | server bootstrap or repair menu |
| `wp-shell-operations.timer/service` | every minute | purge dirty page caches | any site enables cache-auto |
| `wp-shell-cloudflare-ips.timer/service` | weekly | refresh official proxy CIDRs | Cloudflare real-IP mode enabled |
| `wp-shell-redis-<pool>.service` | continuous | private Redis server | per-site explicit isolation |
| `/etc/cron.d/wp-shell-<pool>` | every five minutes | due WP-Cron events | per-site explicit system Cron |
| `/etc/cron.d/wp-shell-aide` | weekly | low-priority AIDE check | explicit AIDE setup |

Only the WP-Cron entry and Cloudflare CIDR refresher have a plausible v11 Core justification, and both remain optional.

## Current backup contract

`backup_site()` currently provides substantial safety:

- per-site lock is inherited from the global process lock;
- root-only final directory with `.incomplete.*` staging;
- file-size and database-size disk headroom checks with 256MB reserve;
- exclusion of cache, backups, logs, and WP-CLI state inside imported roots;
- `mariadb-dump --single-transaction --quick` with a restricted per-site account;
- manifest with domain/database/version/time;
- exactly three SHA256 entries;
- gzip and tar readability checks;
- atomic directory rename only after verification;
- optional remote upload and verification before retention;
- deletion disabled by default because retention defaults to zero.

The local backup and verification path is Core. Remote upload and automatic retention/scheduling are separate concerns.

## Restore comparison

### A. Current 10.0.4 restore

Current `restore_site()`:

1. validates ID, backup checksums, domain manifest, gzip/tar readability, and basic archive path/link/device safety;
2. requires the managed Nginx maintenance rule and no existing marker;
3. creates a normal safety backup, but does not retain or print its exact ID as recovery metadata;
4. extracts to `/tmp`;
5. creates Nginx and WordPress maintenance markers;
6. runs `rsync --delete`, database import, permissions, Redis reconnection, and `core is-installed`;
7. clears caches and removes the Nginx maintenance marker only after the subshell succeeds.

Failure can leave maintenance enabled, which is safer than serving a partially restored site, but it does not identify the safety backup or print an exact recovery command. It does not automatically restore the pre-change files/database. Its disposable DB restore test is available only as a separate `backup drill`, not mandatory restore admission.

### B. Previously proposed Phase 2C

The unmerged proposal adds roughly 649 runtime lines and two dedicated test files. It creates a persistent state machine with states from initialization through source validation, maintenance, safety snapshot, file/database application, validation, commit, rollback, and recovery-required. It adds automatic rollback, explicit `restore status/recover`, fail-closed HTTPS maintenance verification, FPM drain, DB credential preservation, and interruption recovery.

This is robust against more interruption windows, but it makes the Shell script the owner of a cross-filesystem/database transaction protocol. Recovery correctness then depends on journal transitions, terminal-state rules, safety-backup purpose, credential rewriting, rollback branching, and operator understanding of `commit-ready` versus `recovery-required`.

### C. Recommended conservative v11 restore

The smallest acceptable v11 contract is:

```text
deeply verify requested backup
 -> create and verify current-site safety backup
 -> print/record safety backup ID
 -> enter and prove maintenance
 -> restore files
 -> restore database
 -> reapply permissions/managed connection state
 -> verify WordPress
 -> success: exit maintenance
```

If any mutating step fails:

- maintenance stays enabled;
- source and safety backups remain untouched;
- a root-only failure receipt records domain, source ID, safety ID, timestamp, and failed step;
- output includes an exact command such as `wp-shell restore DOMAIN SAFETY_ID --recover --confirm`;
- no automatic rollback is attempted in the same failing process.

The receipt is not a transition journal. It exists only to make the recovery target and maintenance ownership unambiguous. The `--recover` path must revalidate the safety backup, require the existing managed maintenance marker, and leave maintenance enabled again on failure.

Recommendation: C. It meaningfully improves 10.0.4 recoverability while avoiding the state-machine surface of B. S0 does not implement it; S4 must re-evaluate the exact contract and tests after S1-S3 simplify the runtime.

## Current scope conclusion

The project is not complex merely because it is one file. Complexity comes from multiple mutable policy domains sharing the same site arrays, transaction helper, Nginx renderer, WP-CLI wrapper, systemd surface, and menu/router. Removing historical monitoring, automatic decisions, plugin-aware cache orchestration, private services, and general host administration will reduce failure modes more than a source split would. FastCGI transport and a default-off Page Cache Lite remain compatible with that smaller boundary.
