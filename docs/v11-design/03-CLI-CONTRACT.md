# 03 - Proposed v11 CLI Contract

## Goals

The v11 CLI should be predictable enough for both an SSH operator and automation:

- nouns are stable: host, site, capacity, backup, MariaDB;
- read-only commands never initialize directories, migrate files, install packages, reload services, or repair permissions;
- mutating commands state impact and require an explicit confirmation token when they can affect availability, access, or data;
- selectors accept a domain, with numeric IDs retained only as a v10 compatibility convenience;
- success means the effective result was verified, not merely that a candidate file was written;
- output does not expose database, Redis, API, SSH, or WordPress credentials;
- no command silently enables a CDN, cache, plugin, staging, mail, or update policy.

## Global behavior

### Read-only commands

The following must not call `init_paths()`, `migrate_legacy_configs()`, `install_self()`, package management, service reload/restart, or a mutating WP-CLI wrapper:

```text
wp-shell --help
wp-shell --version
wp-shell status
wp-shell audit
wp-shell capacity
wp-shell dry-run apply
wp-shell site list
wp-shell site DOMAIN status
wp-shell mariadb audit
wp-shell cloudflare status
wp-shell cloudflare check SOURCE CLAIMED
wp-shell backup verify DOMAIN BACKUP_ID
```

If required state is absent or corrupt, output is `UNKNOWN`/`BLOCKED` and the command exits nonzero where safety depends on the evidence. It must not create a replacement state file during observation.

### Confirmation

Use exact, non-interactive confirmation flags instead of a generic yes environment variable:

- `--confirm` for managed configuration, worker, migration, backup-restore, and policy changes;
- `--confirm-lockout-risk` for SSH hardening;
- no implicit confirmation from standard input in automation mode.

The interactive menu may ask a yes/no question, but it must invoke the same confirmed implementation after showing the exact impact.

### Exit status

| Status | Meaning |
|---:|---|
| 0 | Requested operation completed and its defined effective verification passed. |
| 1 | Invalid state, validation failure, unsafe admission, operation failure, or failed strict audit. |
| 2 | Usage error/unknown command. Implementation may initially keep v10's status 1 for compatibility, but the contract should converge here. |
| 3 | Operation is blocked by required v10-to-v11 migration or retained legacy ownership. |

Human-readable output remains English/ASCII on the server. Documentation may be Chinese.

## Core commands

### Install

```text
wp-shell install
```

Contract:

1. Validate Ubuntu 22.04/24.04, x86_64/aarch64, root/sudo, disk, and minimum RAM.
2. Read existing v10/v11 state before writing.
3. Refuse if a required compatibility migration would otherwise lose behavior.
4. Run global PHP capacity admission before PHP pool changes.
5. Install only Core packages.
6. Apply validated, transactional Core configuration.
7. Do not install metrics, dashboard dependencies, backup timer, cache timer, private Redis, staging, remote backup, AIDE, Postfix, or application updates.
8. Do not restart the VPS.

Repeated execution is idempotent. Unchanged services are not reloaded/restarted.

### Status

```text
wp-shell status
```

Compact current state only:

- version/config schema and pending migration;
- Nginx, active PHP-FPM versions, MariaDB, shared Redis, Fail2ban, Certbot timer;
- failed systemd units count;
- physical RAM, available memory, Swap total/used, root/`/var/www` disk;
- site count and current maintenance/failure receipts;
- last managed-configuration transaction;
- deprecated v10 units/features still active.

No historical queries or data collection.

### Audit

```text
wp-shell audit
wp-shell audit --strict
```

Read-only detailed checks:

- configuration syntax and effective FPM pool semantics;
- hard aggregate capacity and effective OPcache reservation;
- MariaDB runtime/effective definitions and legacy risk;
- service listeners and loopback database/Redis isolation;
- per-site identity/path/symlink/`wp-config.php` permissions;
- TLS expiry, backup path exposure, WordPress core checksum, and explicitly managed Cron;
- SSH/UFW state without mutation;
- recent severe log counts, bounded to avoid an unbounded scan;
- retained/deprecated v10 feature state requiring operator action.

`audit` reports findings and exits 0 if the audit itself ran. `audit --strict` exits nonzero for failed required Core invariants. The v10 `security-scan` alias maps to strict mode for one major version.

Action Scheduler-specific SQL is removed. The audit must not run due events, send mail, submit forms, load normal plugins/themes, or change WordPress state.

### Capacity

```text
wp-shell capacity
```

Read-only output must show:

- physical RAM and Swap separately;
- current available memory and relevant current pressure evidence when available;
- non-FPM reserves and their purpose;
- effective OPcache per active PHP version;
- worker memory baseline and any current-PSS upward adjustment;
- every effective default pool and managed site pool;
- current aggregate workers and estimated resident exposure;
- desired/manual limits from `/etc/wp-shell/tuning.v1`;
- safe/blocked/unknown result and exact blocking reason.

It does not produce a recommendation or change a limit.

Worker estimate rules:

1. Start at the retained conservative baseline from v10, documented as an estimate rather than a bound.
2. Inspect current managed FPM process PSS when available.
3. Apply a safety margin and only raise, never lower, the baseline.
4. Do not persist a monitoring history solely to refine this value.
5. Do not use Swap as worker capacity.
6. Treat unknown effective pools as `BLOCKED` for mutation.

### Apply and dry-run

```text
wp-shell dry-run apply
wp-shell apply --confirm
```

`dry-run apply` is read-only and prints exact managed areas, capacity blockers, migration blockers, and expected reload/restart scope.

Confirmed apply owns only:

- Core Nginx global/default-host/site transport/security template;
- Core PHP INI, default pool, per-site pool, and effective semantic validation;
- conservative MariaDB baseline and legacy admission;
- shared loopback Redis baseline without plugin activation;
- Fail2ban SSH jail;
- site/operation logrotate;
- Certbot Nginx deploy hook;
- explicit production WordPress constants and secure permissions for managed sites.

It does not own old page cache, private Redis, remote backup, staging, HSTS/header policy, application updates, SSH, UFW, AIDE, mail, or unattended-upgrades unless an explicit separate Core command is invoked.

Apply sequence remains:

```text
load/validate state
 -> compatibility preflight
 -> hard host capacity admission
 -> render candidates
 -> validate candidates
 -> transaction backup
 -> atomic replacement
 -> effective/service validation
 -> reload only changed services
 -> post-reload verification
 -> commit fingerprints
```

### Rollback

```text
wp-shell rollback [TRANSACTION_ID] --confirm
```

Restores only files/symlinks recorded by the managed-configuration transaction and reloads/restarts only marked services after syntax validation. It refuses when a committed target's fingerprint changed later.

Rollback is not a WordPress content/database restore and must never be described as one.

### Explicit v10 migration

```text
wp-shell migrate v10
wp-shell migrate v10 --confirm
```

Without confirmation, report only:

- schemas and wrappers detected;
- deprecated units active;
- metrics database/cursors;
- automatic tuning state;
- page/object cache policies;
- private Redis instances;
- remote backup policies and timer;
- staging/custom Nginx state;
- exact actions that require confirmation or manual replacement.

Confirmed migration performs only approved, reversible ownership changes. It does not delete historical data, unit files, Nginx custom configuration, remote data, Redis instances, or administrator files. Features with unresolved external replacement, especially remote backups and active page caching, remain blockers rather than being silently stopped.

## Site commands

### List and status

```text
wp-shell site list
wp-shell site DOMAIN status
wp-shell site DOMAIN status --verbose
```

List fields:

- domain and canonical host;
- absolute WordPress root;
- managed/imported mode;
- PHP version;
- per-site runtime identity;
- effective `pm.max_children` or `UNKNOWN`;
- compatibility flags such as legacy page cache/private Redis/staging/remote backup.

Status is current-state only. Verbose output may add TLS, core checksum, permissions, Nginx route, Cron, and backup age calculated from the filesystem. It does not query historical SQLite data.

### Add

```text
wp-shell site add
```

Interactive inputs remain limited to infrastructure/lifecycle facts:

- base domain and optional `www` alias/canonical choice;
- administrator email, username, and site title;
- PHP version when different from the environment default;
- optional WooCommerce installation only when explicitly requested.

Do not ask about page cache, object-cache plugin, CDN, staging, HSTS, or theme/plugin behavior.

The new site is first built in memory with one ondemand worker. Global capacity admission runs before `sites.v3`, database credentials, site policy, user, package, service, Nginx, certificate, or WordPress writes.

### Import

```text
wp-shell site import
```

Preserve the v10.0.4 order:

```text
identify WordPress target
 -> validate non-root readable owner and safe path
 -> detect target PHP from Nginx
 -> fall back to DEFAULT_PHP_VERSION only when necessary
 -> append only to in-memory state
 -> run global capacity admission
 -> persist sites.v3 and minimal user policy only on success
```

Import does not rewrite Nginx, PHP pools, WordPress constants, Redis, cache, permissions, database, or plugins. Those changes require a later explicit deploy/adopt operation.

### Deploy/repair

```text
wp-shell site deploy DOMAIN
```

For a new managed site: create identity/storage/database, ACME/TLS, Core Nginx/FPM, verified WordPress ZIP, safe config/constants, and final permissions.

For an imported site: show the exact configuration ownership change and require confirmation before replacing Nginx/FPM behavior. Do not infer cache/plugin/CDN state.

Before any pool write, admission includes all existing effective pools plus the requested site. Final `core is-installed` and effective FPM checks occur before the site is marked managed.

### Manual workers

```text
wp-shell site DOMAIN workers N
wp-shell site DOMAIN workers N --confirm
```

Without confirmation, print the prospective whole-host capacity calculation.

With confirmation:

1. Validate `N` as a positive bounded integer.
2. Read all current effective default/site pools using `php-fpm -tt`.
3. Verify the selected pool is a regular wp-shell-managed file and agrees with the effective value.
4. Replace only that site's current value in the prospective aggregate.
5. Refuse if the final aggregate exceeds the hard budget or any evidence is unknown.
6. Render a candidate pool file and validate FPM.
7. Save the desired value in existing `tuning.v1` only after aggregate admission.
8. Use the managed-file transaction, reload only the affected PHP version, then re-read the effective value.
9. Roll back pool and desired state if validation/reload/effective verification fails.

There is no automatic recommendation, WooCommerce weighting, silent clamping, or redistribution of other sites.

If a legacy host is already overcommitted across multiple sites, a single-site command may be unable to produce a safe final aggregate. S1 must decide between an explicit atomic multi-site form or a confirmed `apply` plan that sets all unpinned sites to one; it must not allow a sequence of successful-but-still-unsafe pool writes.

### Core verify and repair

```text
wp-shell site DOMAIN core verify
wp-shell site DOMAIN core repair --confirm
```

Keep strict official ZIP/checksum verification. Repair requires a verified pre-change backup, preserves `wp-content`/`wp-config.php`/database, rejects unsafe paths, removes detected truncated artifacts only within known core paths, and reapplies permissions.

### Optional simple site security/operations

Advanced help may retain:

```text
wp-shell site DOMAIN cron enable|disable|status
wp-shell site DOMAIN xmlrpc enable|disable|status
wp-shell site DOMAIN login-limit enable|disable|status
wp-shell site DOMAIN isolate --confirm
wp-shell site DOMAIN maintenance on|off|status
```

These commands must remain opt-in, narrowly scoped, validated, and idempotent. `maintenance off` refuses without confirmation when a restore-failure receipt exists.

## Backup commands

```text
wp-shell backup DOMAIN
wp-shell backup-all
wp-shell backup verify DOMAIN [BACKUP_ID] [--deep]
```

`backup` and `backup-all` create local backups only in Core. They retain `.incomplete` staging, disk admission, dedicated DB credentials, checksum manifest, archive/SQL tests, atomic finalization, no-deletion default, and safe imported-root exclusions.

`verify` performs checksum/manifest/archive/SQL compression validation. `--deep` also extracts safely and imports SQL into a disposable restricted database without executing website PHP.

No Core command configures an off-host remote or claims that a local backup is disaster recovery.

## Restore command

```text
wp-shell restore DOMAIN BACKUP_ID
wp-shell restore DOMAIN BACKUP_ID --confirm
wp-shell restore DOMAIN SAFETY_BACKUP_ID --recover --confirm
```

Without confirmation, validate arguments and print impact, source backup, proposed safety-backup destination, maintenance behavior, and recovery contract without changing state.

Confirmed normal restore follows the conservative contract in `01-CURRENT-SCOPE-INVENTORY.md`. Success means WordPress verification passed and maintenance was exited. Failure means maintenance remains, a root-only failure receipt names the exact failed step/source/safety backup, and output contains the exact `--recover` command.

`--recover` is admitted only when the receipt, requested safety backup, domain, and existing managed maintenance marker agree. It is not a general bypass of maintenance safeguards.

## MariaDB commands

```text
wp-shell mariadb audit
wp-shell mariadb migrate-legacy --confirm
```

Retain the v10.0.4 contract unchanged unless a regression is found: effective/runtime distinction, all relevant definitions, administrator-file preservation, conservative low-memory gate, candidate/full validation, restart only on effective change, health/runtime proof, and exact rollback.

## Cloudflare real-IP commands

```text
wp-shell cloudflare enable --confirm
wp-shell cloudflare disable --confirm
wp-shell cloudflare update
wp-shell cloudflare status
wp-shell cloudflare check SOURCE_IP CLAIMED_IP
```

The namespace means real-IP compatibility only. Help must explicitly say it does not manage DNS, cache, APO, WAF, firewall bans, or API tokens.

## Compatibility aliases

Keep for v11 with a warning and canonical replacement:

| Alias | Canonical replacement |
|---|---|
| `list` | `site list` |
| `add-site` | `site add` |
| `deploy DOMAIN` | `site deploy DOMAIN` |
| `import` | `site import` |
| `optimize --confirm` | `apply --confirm` |
| `security-scan` | `audit --strict` |
| `backup drill ...` | `backup verify ... --deep` |
| `wp-vps-manager.sh` | `wp-shell` through `legacy-vps` |
| `deploy-single-wordpress.sh` / `wp-single-manager` | unambiguous `site` command through `legacy-single` |

Removed monitoring/cache/staging/update commands should not pretend success. They print a concise deprecation/removal message, state whether legacy configuration is still active, and point to migration/standard-tool guidance.
