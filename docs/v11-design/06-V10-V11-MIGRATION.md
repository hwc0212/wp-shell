# 06 - v10.0.4 to v11 Migration Design

## Objectives

The migration is an ownership transition, not a cleanup script. It must let v11 become smaller without silently changing a working site's public behavior, stopping the only off-host backup, weakening isolation, losing historical evidence, or deleting administrator configuration.

`10.0.4` at commit `8dd604bea4f201a797ac7e8912a843c32c6e9c4f` is the frozen behavioral reference for this design. v11 must continue reading existing v10 schemas until a confirmed migration has either adopted their Core meaning or classified them as retained compatibility state.

## Migration states

| State | Meaning | Permitted v11 behavior |
|---|---|---|
| `CLEAN` | No v10-only active behavior is detected | Core read/write commands may proceed |
| `COMPATIBLE` | Old data exists but no retired active producer/consumer is required | Preserve and report it; Core writes may proceed outside its ownership |
| `MIGRATION_REQUIRED` | A retired timer, unit or derived-state producer is active | Read-only commands work; affected apply/install path exits with migration status |
| `EXTERNAL_REPLACEMENT_REQUIRED` | Remote backup, cache, private Redis or staging behavior would be lost/changed | Do not disable it; block the affected ownership transition |
| `CONFLICT` | Effective state cannot be attributed safely or is corrupt | Fail closed; administrator review required |

The state is computed from evidence. It must not be inferred only from a version string or the existence of `/etc/wp-shell/environment.v1`.

## Read-only preflight

```text
wp-shell migrate v10
```

The unconfirmed command performs no initialization or repair. It reports:

- executable version and known configuration schemas;
- valid and invalid site records, absolute roots, PHP versions and effective pool ownership;
- legacy wrappers and known automation command forms;
- active/enabled metrics, operations, backup, Cloudflare, private-Redis and other wp-shell units;
- system and per-site Cron files owned by wp-shell;
- SQLite metrics database, cursors, recommendations and tuning desired state;
- shared/private Redis policy and live instance evidence;
- FastCGI page-cache policy, Nginx includes, cache roots, invalidation plugin/queue and public-behavior risk;
- remote backup policy, encryption metadata, configured transport and recent local/remote success evidence when it can be inspected without credentials in output;
- staging state, roots, routes and WordPress environment markers;
- AIDE, Postfix, unattended-upgrades, SSH/UFW and header/HSTS policies previously written by wp-shell;
- unknown keys/files and administrator-owned conflicts that v11 will not mutate;
- exact actions proposed for `--confirm`, explicit blockers and rollback inputs.

It redacts database credentials, Redis secrets, encryption keys, tokens, remote URLs containing credentials and WordPress passwords.

## Pre-migration recovery point

Before the first confirmed v11 ownership change, migration must create a root-only manifest and exact copies of configuration it will touch. The manifest records:

- v10 executable SHA-256 and source version;
- copies and SHA-256 values of `/etc/wp-shell` files being changed;
- copies and fingerprints of generated `/etc/nginx`, `/etc/php`, `/etc/mysql`, Redis, logrotate, systemd and Cron targets being changed;
- enabled/active state of every wp-shell unit being changed;
- the chosen disposition of each removed feature;
- the last verified local backup identifier per affected site;
- confirmation that a configuration backup is not a WordPress files/database backup.

The old executable may be retained in this root-only migration backup for rollback. It must not be silently installed as a second command in `PATH` or treated as a security-updated release.

No content/database restore point should be fabricated from configuration copies. Where a migration can alter site behavior, it requires a recent verified local site backup under the existing backup contract.

## Confirmed migration

```text
wp-shell migrate v10 --confirm
```

The confirmed command operates as a managed transaction:

```text
read-only preflight
 -> verify blockers were explicitly resolved
 -> create migration manifest/backups
 -> render candidate Core state
 -> validate all candidates
 -> stop/disable only confirmed retired producers
 -> atomically adopt Core state
 -> validate effective services and sites
 -> commit fingerprints and previous unit states
```

On failure it restores exact files and unit enablement/active states that the same operation changed. It does not delete v10 data or compensate by changing unrelated site settings.

## Feature-by-feature disposition

### Configuration schemas and site records

- Preserve valid `environment.v1`, `sites.v3`, `databases/<domain>.v1`, `redis.secret`, `tuning.v1`, `opcache.v1`, `host-policy.v1`, per-site policy leaves and recognized legacy migrations.
- Keep current site order/IDs for compatibility, but make domain the canonical selector.
- Retain unknown per-site policy keys verbatim. v11 may label them `compatibility-owned` but cannot discard them while copying a policy.
- Preserve the imported-site PHP detection/fallback and global capacity admission behavior from 10.0.4.
- Corrupt records block mutation; no best-effort rewrite that drops malformed or unknown fields.

### Metrics, dashboard and automatic tuning

- `metrics.sqlite3`, cursors, health state and recommendation files remain root-owned, read-only historical artifacts after migration.
- Confirmed migration stops/disables the metrics timer/service and records their previous state. It does not delete unit files, the database or logs.
- A minimal one-major-version compatibility route for an already scheduled `metrics collect` invocation may exit successfully with a deprecation warning and no state mutation until confirmed migration disables the unit. It must not print `collector OK` or create empty samples.
- `/etc/wp-shell/tuning.v1` is adopted as manual desired worker state. Recommendation provenance/history is not needed to honor an explicit current value.
- `dashboard`, `report`, `analyze` and automatic `tune --apply` become deprecation errors with the replacement command where one exists; no synthetic history is generated.

### PHP-FPM and OPcache

- Keep effective default/site-pool inspection, hard aggregate admission, manual desired limits and semantic post-write validation.
- Remove only the historical-metrics input after the current-PSS upward estimator is available.
- Preserve a safe existing OPcache override during the compatibility window. v11 stops offering auto-tune/mutation; it does not revert the override to distribution defaults during normal apply.
- Conflicting administrator OPcache configuration remains an audit result and can block PHP mutation; it is not deleted.

### Private Redis and object cache

- New v11 sites do not create private Redis instances or install/activate an object-cache plugin.
- Existing private Redis configurations, password files, sockets, instance services and site policies remain untouched and visible in status.
- Core apply must either preserve their compatible PHP/WordPress connection state or refuse the site change. It must not fall back silently to shared Redis, which could mix prefixes or expose credentials.
- Migration to a plugin/vendor/external owner is a separate explicit runbook. Only after connection and cache behavior are verified may the old instance be stopped; files and secrets follow an administrator-approved retention policy.

### FastCGI Page Cache Lite and legacy operations timer

- FastCGI transport remains Core and is not a migration target: preserve per-site Unix sockets, required parameters, timeout/buffer compatibility and effective FPM/socket verification.
- v11 offers Page Cache Lite as a default-off, explicit per-site option with on/off/status/manual clear.
- Compatible v10 `page-cache` state is adopted without changing its enabled/disabled value. The v11 renderer uses one conservative generic WordPress bypass set and adds WooCommerce bypasses only when WooCommerce is an explicit site registry property.
- Plugin/theme/RFQ/Pretty Links-specific exclusions, automatic Cloudflare/APO coordination, metrics and tuning are not imported into the generic policy. Existing custom Nginx exclusions remain administrator-owned and byte-preserved.
- Existing cache-enabled sites retain effective v10 public behavior until a preflight proves the Lite candidate is equivalent or the operator confirms a reviewed difference. An unrepresentable custom behavior blocks affected apply rather than being silently dropped.
- Automatic invalidation is separate from Page Cache Lite. An operations-timer compatibility handler may remain only long enough to avoid broken scheduled commands; confirmed migration disables its producer and preserves the MU plugin/marker/unit data unless the operator explicitly removes owned artifacts.
- The migration report must distinguish configured cache directives from proof of working HIT/bypass behavior. It verifies representative anonymous HIT, admin/login bypass and explicit WooCommerce dynamic-route bypass before ownership changes.
- Cache directories are never automatically deleted. A confirmed manual clear is bounded to the selected site's validated wp-shell-owned cache root and must not follow symlinks.

### Remote backup

- Local backup, verify and backup-all remain Core.
- v11 does not create new remote policies. Existing remote-upload behavior must remain compatible until an external replacement is configured and verified.
- If the current wp-shell timer is the only off-host protection, migration is `EXTERNAL_REPLACEMENT_REQUIRED`; it cannot merely turn the timer into local-only backup.
- Replacement evidence includes a recent successful off-host object, encryption/key recovery understanding, retention policy and a documented restore/download path. A configured destination alone is insufficient.
- Remote objects, rclone configuration, encryption metadata and logs are never deleted.

### Cloudflare

- Preserve only official-CIDR real-IP trust and the optional safe updater.
- Existing sites without Cloudflare remain unchanged; no proxy assumption is added.
- Failed downloads retain the last validated include.
- No Cloudflare API token is required or migrated. API firewall, DNS, APO and purge ownership are outside Core.

### Staging and application-specific operations

- Existing staging roots and routes are detected and retained; v11 does not create new clones or rewrite them as ordinary production sites automatically.
- No staging database/files are deleted. WordPress environment, mail and Cron behavior remain operator/plugin responsibilities until an explicit external migration.
- Bulk core/plugin/theme upgrades and Action Scheduler-specific commands are removed from new workflows. Existing scheduled application tasks are not run as a migration test.

### Generic host controls

- Existing SSH/UFW changes stay in force; v11 retains explicit safety/status commands and does not relax them.
- AIDE, Postfix and unattended-upgrades become administrator/distribution-owned. Migration records their wp-shell-managed files but does not remove or disable these protections.
- HSTS/strict-header compatibility state is preserved for existing sites. v11 does not newly enable `includeSubDomains` or `preload`, and normal apply cannot silently remove a header policy already serving traffic.

### Compatibility wrappers

- `wp-vps-manager.sh` and `deploy-single-wordpress.sh` remain thin forwarders for v11 and emit a deprecation warning.
- Wrapper behavior is tested against paths containing spaces and forwarded arguments.
- Removal occurs no earlier than v12 and requires release-note notice. v11 does not generate new copies as site-specific shortcuts.

## Installation and timer race

Replacing `/usr/local/sbin/wp-shell` can occur before the operator runs migration. To avoid turning retired systemd timers into noisy or misleading failures:

1. v11 retains small, non-mutating compatibility handlers for known timer entry points during the v11 compatibility window.
2. `status` and `migrate v10` prominently report active deprecated units.
3. Confirmed migration disables the exact retired producer and records previous state.
4. Compatibility handlers never claim work was collected/uploaded/processed when it was not.
5. Unit files and data are retained; S3 may remove handlers only after migration-state evidence proves no active caller remains.

## Rollback design

```text
wp-shell rollback MIGRATION_TRANSACTION_ID --confirm
```

Rollback restores only items recorded by the migration transaction:

- exact previous files/symlinks when their current fingerprints still match the transaction output;
- previous enabled/disabled and active/inactive unit state;
- prior Core configuration after syntax validation;
- the v10 executable only as an explicit migration rollback action with checksum verification.

It refuses to overwrite post-migration administrator edits. It does not restore WordPress content/database state, recreate deleted remote objects, or claim to reverse external replacement work.

After rollback, validate Nginx, every affected PHP-FPM version, MariaDB health, Redis listeners, effective site pools, WordPress read-only checks and representative public routes. Prefer reload; restart MariaDB only when changed options require it.

## Compatibility duration

| Compatibility item | v11 requirement | Earliest removal |
|---|---|---|
| Read v10 config/site/policy schemas | Required | Only after an explicit later schema migration with rollback |
| Legacy command wrappers | Warn and forward | v12 |
| Retired timer entry-point handlers | Non-mutating compatibility plus status warning | After confirmed migration evidence; no earlier than a v11 minor release |
| Existing generic page-cache state | Adopt as Page Cache Lite without changing enabled state | Core; no planned removal |
| Custom/plugin-specific cache rules and cache-auto | Preserve or block affected apply; explicit migration | v12 or after per-site ownership transfer |
| Existing private Redis awareness | Preserve or block affected apply | No fixed date; only after explicit instance migration |
| Existing remote backup upload | Preserve until verified external replacement | No fixed date; never time-expire protection silently |
| Historic metrics database | Preserve as inactive data | Administrator retention decision only |
| Unknown policy keys/admin files | Preserve | Never automatically remove |

## Migration acceptance checks

A migration succeeds only when:

- Core configuration candidates and effective service state validate;
- all managed sites keep their effective PHP identities and pass aggregate capacity admission;
- public Nginx routing for existing sites is unchanged unless explicitly selected;
- no active remote backup, cache invalidation, private Redis or staging behavior was silently removed;
- stopped/disabled unit states match the confirmed plan;
- historical data and administrator files still exist with safe permissions;
- repeated preflight and confirmed migration produce no further writes or service reloads;
- logs contain no secrets;
- the rollback transaction and exact operator actions are printed.

## Conditions that block migration

- corrupt/ambiguous site or policy state;
- effective PHP pools disagree with managed ownership or exceed the hard budget;
- unsafe effective MariaDB configuration under the current risk gate;
- no verified backup before a behavior-changing site migration;
- the only off-host backup would stop;
- active custom cache/cache-auto, private Redis or staging behavior cannot be preserved and no reviewed ownership transition is confirmed;
- a candidate fails syntax/semantic validation;
- current files differ from fingerprints captured after planning;
- inadequate disk space for exact transaction/configuration backups.

The remedy is explicit operator action, not `--force`.
