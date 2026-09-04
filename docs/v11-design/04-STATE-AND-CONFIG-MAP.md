# 04 - State and Configuration Map

## Scope and counting model

The current runtime uses two primary state roots:

- `/etc/wp-shell`: authoritative configuration, secrets, policy, compatibility backups, and configuration transaction history;
- `/var/lib/wp-shell`: historical/derived metrics, cursors, locks, recommendations, and transient operation stages.

There is no single fixed file count because most state is per-site or per-transaction. This document counts **file classes** and gives formulas where possible. It also lists related managed files outside those roots because migration decisions cannot be made safely without them.

The experimental `wp-shell-v11.sh` does not casually install over `/usr/local/sbin/wp-shell`; its optional development path is `/usr/local/sbin/wp-shell-v11`. It intentionally does not duplicate every configuration namespace. Consequently `/etc/wp-shell`, `/var/lib/wp-shell`, existing wp-shell systemd units/timers, Nginx/PHP-FPM/MariaDB/Redis files and `/var/www/<domain>` remain collision points. Mutating v11 bootstrap runs require explicit opt-in and disposable/test hosts until the migration stage defines production ownership.

Migration actions mean:

- **read**: v11 must parse and validate it;
- **preserve**: leave exact existing content unless an explicit operation owns it;
- **reuse**: keep the current schema/meaning in v11;
- **reinterpret**: retain format but narrow the producer/consumer contract;
- **warn**: report retained deprecated state;
- **explicit**: only a confirmed migration may disable or transform it;
- **manual**: administrator owns cleanup or external migration.

## `/etc/wp-shell` authoritative files

| Path/class | Owning v10 feature | Core? | Historical/derived? | v11 need | Migration | Eventual removal |
|---|---|---:|---:|---|---|---|
| `environment.v1` | environment mode, default PHP, UFW choice | yes | no | yes | read/reuse; tolerate known v10 fields | no planned removal |
| `sites.v3` | site registry | yes | no | yes | read/reuse; do not rewrite merely to rename fields | no planned removal |
| `databases/<domain>.v1` | managed DB name/user/password | yes | no, secret | yes for managed sites | read/preserve mode 0600; never log decoded password | no planned removal while wp-shell owns DB lifecycle |
| `redis.secret` | shared Redis authentication | transitional Core | no, secret | yes for v10 hosts; new design decision remains | read/preserve; rotation remains compatibility safety | possibly after a separately designed Unix-socket/auth migration, never S1 |
| `tuning.v1` | automatic/manual PHP child overrides | yes after reinterpretation | no | yes | reinterpret as explicit manual worker targets; remove only automatic producer | no near-term removal because reuse avoids schema churn |
| `opcache.v1` | desired OPcache MB/strings by PHP version | compatibility | no | read/preserve, no normal mutation | preserve exact safe values; capacity uses effective FPM values, not this file alone | possible after v12 migration to administrator-owned INI |
| `host-policy.v1` | Cloudflare, Redis override, external mail | mixed | no | partially | keep known keys; warn on unsupported keys; never drop unknown keys | only after key-specific migrations |
| `last-transaction` | pointer to last config transaction | yes | derived pointer | yes | reuse; validate ID and target directory | no planned removal |

Fixed authoritative singleton classes: seven, although some files are optional until first use. `databases/<domain>.v1` is an additional per-site class rather than a singleton.

## `/etc/wp-shell/site-policy/<domain>/` leaves

Current `set_site_policy()` stores one root-only file per key. Not every site has every key.

| Key | v10 owner/meaning | v11 disposition | Migration behavior |
|---|---|---|---|
| `user` | non-root site runtime identity | KEEP | Required; validate account/home/group and preserve. |
| `page-cache` | FastCGI page cache enabled/disabled | KEEP optional | Reuse for Page Cache Lite; default off, explicit on/off, generic or explicit-WooCommerce bypass profile. |
| `object-cache` | Redis Object Cache integration state | EXTERNALIZE | Observe/preserve; do not install, disable, or rewrite plugin automatically. |
| `redis-mode` | shared or isolated instance | DEPRECATE for isolated | Preserve service/connection; block automatic downgrade. |
| `redis-memory` | private Redis limit | DEPRECATE | Preserve with isolated instance; report only. |
| `redis-secret` | private Redis credential | DEPRECATE, secret | Preserve 0600; never display; remove only after verified explicit migration. |
| `backup-remote` | rclone crypt target | EXTERNALIZE | Migration blocker until replacement is acknowledged; never delete remote data. |
| `cache-auto` | MU-plugin/timer invalidation mode | REMOVE | Confirmed migration may disable owned timer/plugin; policy retained until verified. |
| `login-limit` | per-site Nginx login rate limit | KEEP optional | Preserve; requires verified real IP when proxied. |
| `staging-path` | nested staging absolute path | EXTERNALIZE | Preserve/report; no path mutation or cleanup. |
| `staging-url` | nested staging URL prefix | EXTERNALIZE | Preserve/report with custom Nginx file. |
| `staging-redis-prefix` | staging cache isolation/off | EXTERNALIZE | Preserve WordPress constants; do not guess replacement. |
| `hsts` | managed HSTS enabled/disabled | DEPRECATE | Preserve render behavior; explicit transfer to CDN/custom Nginx. |
| `xmlrpc` | XML-RPC enabled/disabled | KEEP optional | Preserve compatibility-first value. |
| `header-profile` | compatible/strict headers | DEPRECATE | Preserve render behavior; explicit transfer to custom Nginx. |
| `cron-mode` | request/system WP-Cron | KEEP optional | Reuse; cross-check owned Cron file and WordPress constant. |
| `cron-prior` | prior `DISABLE_WP_CRON` value | KEEP supporting state | Reuse to make disable reversible. |

Current maximum known policy leaves: 17 per site. v11 Core target after completed migrations: `user`, optional `page-cache`, optionally `cron-mode`/`cron-prior`, plus optional `login-limit` and `xmlrpc`. Compatibility leaves may remain readable for at least one major version.

Do not consolidate these into one file in S1-S3 merely to reduce filenames. Separate leaves permit narrow ownership and rollback. The semantic reduction comes from fewer active policies, not a format rewrite.

## `/etc/wp-shell` history and snapshots

| Path/class | Contents | Core? | v11 behavior | Retention/cleanup owner |
|---|---|---:|---|---|
| `transactions/<id>/manifest.v1` | label, timestamps, pre-file records, service markers, post fingerprints | yes | read/reuse; keep exact rollback contract | administrator; future documented retention may be explicit only |
| `transactions/<id>/files/*` | exact prior managed files/symlinks | yes | preserve | administrator |
| `migration-backup/<timestamp>/...` | legacy vps/single config copies | compatibility | preserve; use as migration evidence | administrator after verified migration |
| `nginx-backups/<domain>-<timestamp>.<random>/...` | site/cache/custom snapshots before template refresh | compatibility/safety | preserve; S3 may stop creating duplicate snapshots if transaction backup is sufficient, only after proof | administrator |
| `opcache-backups/<timestamp>.<random>/manifest` | previous OPcache file-presence state | deprecated feature | preserve; no new snapshots after mutation UI removal | administrator |
| `opcache-backups/.../zz-wp-shell-opcache.ini` | prior managed INI | deprecated feature | preserve | administrator |
| `opcache-backups/.../opcache.v1` | prior desired state | deprecated feature | preserve | administrator |

Transaction history is unbounded by design in 10.0.4. S0 does not introduce automatic deletion. A future manual prune command would require last-known recovery-point and disk safeguards and is not part of v11 Core planning.

## `/var/lib/wp-shell` current state

| Path/class | Owning feature | Core? | Historical/derived? | v11 need | Migration | Eventual removal |
|---|---|---:|---:|---|---|---|
| `metrics.sqlite3` | historical monitoring/tuner/dashboard | no | historical | no | stop writer explicitly; retain DB | manual after desired export/retention |
| `metrics.sqlite3-wal` | SQLite WAL sidecar | no | derived | no | checkpoint/stop writer before migration; do not delete blindly | manual with DB after service stopped |
| `metrics.sqlite3-shm` | SQLite shared-memory sidecar | no | derived | no | same as WAL | manual |
| `cpu.state` | collector delta cursor | no | derived | no | preserve after timer disabled | manual |
| `pressure.state` | collector CPU delta cursor | no | derived | no | preserve after timer disabled | manual |
| `nginx-<hash>.offset` | per-site log cursor | no | derived | no | preserve after timer disabled | manual |
| `size-<hash>.state` | cached directory-size reading | no | derived | no | preserve after timer disabled | manual |
| `collector.lock` | collector flock inode | no | derived | no | harmless after stop; preserve | manual |
| `last-recommendations.tsv` | analysis output | no | derived | no | preserve as historical operator evidence only | manual |
| `pending-tuning-recommendations.tsv` | tuner confirmation plan | no | derived | no | invalidate with warning; never apply in v11 | manual |
| `cron-<pool>.lock` | old internal cron route lock | no for current Cron file | derived | no | current Cron uses site-root lock; preserve | manual |
| `cron-<pool>.success` | old internal Cron success timestamp | no | derived | no | site status stops depending on it | manual |
| `operations.lock` | page-cache event worker | no | derived | no | stop operations timer first | manual |
| `.sample.<random>/` | collector transaction staging | no | transient/crash remnant | no | never treat as authoritative | manual after confirming no collector process |
| `.tuning.<random>/` | auto-tuner rollback staging | no | transient/crash remnant | no | never apply; warn if present | manual review |
| `.isolation.<random>/` | per-site UID migration rollback stage | Core operation remnant | transient/crash remnant | only for recovery evidence | do not auto-delete unknown remnant | manual after recovery review |
| `.redis-isolation.<random>/` | private Redis migration rollback stage | deprecated | transient/crash remnant | no normal use | preserve/report | manual after service/config review |

The metrics database contains six tables:

```text
system_samples
site_samples
service_samples
sample_health
system_pressure
redis_site_samples
```

All six and their indexes leave v11 Core. Current status/audit/capacity must not depend on the database after S1.

Approximate current state formula under `/var/lib/wp-shell`:

```text
3 SQLite files when WAL is active
+ 4 singleton cursor/lock/recommendation classes
+ 1 nginx offset per site
+ about 4 size-cache files per site
+ up to 2 legacy cron files per site
+ transient operation directories
```

The exact count varies with site activity and crashes. v11 Core target is no historical database/cursors/recommendations. Only operation locks that protect an active Core action should remain, preferably under `/run` when persistence is unnecessary.

## Related managed configuration outside primary roots

### Nginx

| Path | v11 disposition |
|---|---|
| `/etc/nginx/conf.d/wp-shell-log-format.conf` | KEEP, but remove fields used only by historical aggregation if no security value. Verified client/edge IP can remain in logs. |
| `/etc/nginx/conf.d/wp-shell-global.conf` | KEEP minimal `server_tokens` and login-limit primitives. |
| `/etc/nginx/sites-available/00-wp-shell-default` and enabled link | KEEP unknown-Host fail-closed behavior. |
| `/etc/nginx/sites-available/<domain>` and enabled link | KEEP Core routing/security/TLS; compatibility renderer must preserve active v10 optional behavior. |
| `/etc/nginx/conf.d/wp-cache-<domain>.conf` | KEEP optional as Page Cache Lite's per-site cache path/zone; adopt compatible v10 state without discarding custom exclusions. |
| `/etc/nginx/wp-shell-custom/<domain>/*.conf` | PRESERVE as administrator/compatibility extension surface; never delete wholesale. |
| `/etc/nginx/wp-shell-custom/<domain>/10-staging.conf` | EXTERNALIZED legacy state; preserve. |
| `/etc/nginx/wp-shell-custom/<domain>/20-cache-exclusions.conf` | EXTERNALIZED legacy state; preserve. |
| `/etc/nginx/wp-shell-custom/<domain>/30-login-limit.conf` | KEEP when policy enabled. |
| `/etc/nginx/conf.d/wp-shell-cloudflare-realip.conf` | KEEP optional real-IP compatibility. |

### PHP-FPM/OPcache

| Path | v11 disposition |
|---|---|
| `/etc/php/<version>/fpm/conf.d/99-wp-shell.ini` | KEEP conservative Core PHP baseline. |
| `/etc/php/<version>/fpm/conf.d/zz-wp-shell-opcache.ini` | PRESERVE/compatibility; no normal tuning UI. |
| `/etc/php/<version>/fpm/pool.d/zz-wp-shell.conf` | KEEP one-worker ondemand default pool and effective validation. |
| `/etc/php/<version>/fpm/pool.d/99-wp-shell.conf` | recognized legacy file; keep migration logic until deployed hosts have transitioned. |
| `/etc/php/<version>/fpm/pool.d/wp-shell-<pool>.conf` | KEEP per-site pool and manual worker setting. |

Administrator-created later INI/pool files remain untouched. Their effective overrides can block admission/apply.

### MariaDB

| Path | v11 disposition |
|---|---|
| `/etc/mysql/mariadb.conf.d/60-wp-shell.cnf` | KEEP conservative loopback/charset/durability/log baseline and safe existing managed tuning. |
| `.../50-wordpress.cnf` in `conf.d` or `mariadb.conf.d` | legacy; audit and explicit migration only. |
| all other `/etc/mysql/**/*.cnf` | administrator/distribution owned; audit, never mutate automatically. |

### Redis

| Path | v11 disposition |
|---|---|
| `/etc/redis/wp-shell.conf` | KEEP shared local Redis baseline for existing hosts; simplify new-install ownership later only with migration design. |
| `/etc/systemd/system/redis-server.service.d/wp-shell.conf` | KEEP while shared managed config is in use. |
| `/etc/wp-shell-redis/<pool>.conf` | deprecated private Redis; preserve/report, no new creation. |
| `/etc/systemd/system/wp-shell-redis-<pool>.service` | deprecated private Redis; preserve active service until explicit migration. |

### Units, Cron, and host files

| Path | v11 disposition |
|---|---|
| `wp-shell-metrics.service/timer` | retired; explicit disable, retain files/data. |
| `wp-shell-operations.service/timer` | retired with cache-auto; explicit disable, retain files until verified. |
| `wp-shell-backup.service/timer` | deprecate/externalize schedule; do not silently stop an operator's only backup job. |
| `wp-shell-cloudflare-ips.service/timer` | KEEP only when optional real-IP mode enabled. |
| `/etc/cron.d/wp-shell-<pool>` | KEEP optional system WP-Cron. |
| `/etc/cron.d/wp-shell-aide` | externalized; preserve. |
| `/etc/aide/aide.conf.d/99_wp_shell` | externalized; preserve. |
| `/etc/fail2ban/jail.d/wp-shell.local` | KEEP SSH-only jail. |
| `/etc/logrotate.d/wp-shell-sites` | KEEP. |
| `/etc/logrotate.d/wp-shell-operations` | KEEP but rename/content review belongs to docs/implementation, not S0. |
| `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx` | KEEP validated reload hook. |
| `/etc/ssh/sshd_config.d/99-wp-shell-hardening.conf` | KEEP if explicitly installed; never remove in migration. |
| `/etc/apt/apt.conf.d/52wp-shell-updates` | externalized; preserve administrator policy. |
| `/etc/postfix/main.cf` | administrator/service-owned after prior mutation; preserve and report only. |

## Site-root persistent data

Although outside the requested primary roots, these paths are required for safe migration:

| Path | Role | v11 disposition |
|---|---|---|
| `/var/www/<domain>/public` or imported root | WordPress authority | KEEP with path/symlink boundaries. |
| `/var/www/<domain>/logs` | site logs | KEEP. |
| `/var/www/<domain>/backups` | local backups | KEEP. |
| `/var/www/<domain>/cache` | FastCGI Page Cache Lite data | KEEP optional | use only the validated per-site root; manual clear requires confirmation and must not follow symlinks. |
| `/var/www/<domain>/.wp-cli` | isolated WP-CLI home/cache | KEEP. |
| `/var/www/<domain>/.wp-shell-maintenance` | fail-closed maintenance marker | KEEP. |
| `/var/www/<domain>/.wp-shell/cache-dirty` | cache-auto event marker | retire explicitly with feature. |
| `/var/www/<domain>/.wp-shell/cron.lock` | current system Cron lock | KEEP with optional Cron. |
| `/root/wordpress-credentials-<domain>.txt` | one-time generated administrator credential | compatibility/security-sensitive | status warns; operator deletes after secure capture. Never migrate into repository/state. |

## v11 target state model

After all explicit migrations, a typical v11 managed site should require:

```text
/etc/wp-shell/environment.v1
/etc/wp-shell/sites.v3
/etc/wp-shell/databases/<domain>.v1
/etc/wp-shell/tuning.v1              # manual worker targets only, optional
/etc/wp-shell/site-policy/<domain>/user
/etc/wp-shell/site-policy/<domain>/page-cache   # optional, Page Cache Lite
/etc/wp-shell/site-policy/<domain>/cron-*       # optional
/etc/wp-shell/site-policy/<domain>/login-limit  # optional
/etc/wp-shell/site-policy/<domain>/xmlrpc       # optional
/etc/wp-shell/transactions/... and last-transaction
```

No historical monitoring database is required. Removed-feature files remain on upgraded hosts until an operator has verified external ownership and chooses manual cleanup.
