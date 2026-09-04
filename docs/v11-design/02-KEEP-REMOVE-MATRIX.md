# 02 - Keep, Merge, Deprecate, Remove, Externalize Matrix

## Classification meanings

- **KEEP**: remains a supported v11 Core behavior.
- **MERGE**: behavior remains, but moves into a smaller Core command or becomes an internal step.
- **DEPRECATE**: retained temporarily for deployed v10 compatibility, warns, and has a documented removal release.
- **REMOVE**: implementation and entry point leave v11 after an explicit migration handles live state.
- **EXTERNALIZE**: another standard tool or the application/plugin owner should provide the behavior; wp-shell documents the boundary and does not configure it for new sites.

Classification is about product ownership, not immediate deletion. Any row with existing on-host state must follow `06-V10-V11-MIGRATION.md`.

## Feature-level decision matrix

| Feature | Decision | Why / v11 behavior | Existing v10 host behavior |
|---|---|---|---|
| Ubuntu/platform admission | KEEP | Prevents unsupported package/config mutations. | Continue reading current environment state. |
| Required package install | KEEP | Essential installer behavior. Reduce the baseline package list only after removed features no longer need SQLite/libfcgi; retain Python/JQ while surviving safe parsers/release handling use them. | Never auto-remove packages. |
| Managed-file transaction/rollback | KEEP | Prevents configuration corruption and unsafe overwrite. | Preserve transaction history and fingerprint rules. |
| Per-site PHP UID/group/pool/socket | KEEP | Material privilege boundary and capacity control. | Preserve identities; offer explicit migration for legacy `www-data` sites. |
| `wp-config.php` safe write window | KEEP | Prevents both permission failures and writable-secret exposure. | Exact v10.0.4 behavior remains a regression requirement. |
| Imported-site discovery/admission | KEEP | Core lifecycle behavior with important no-partial-persist guarantees. | Read v3 and legacy state; do not infer plugin settings. |
| Effective PHP-FPM semantic validation | KEEP | Required to prove pool limits after include precedence. | Preserve fail-closed `php-fpm -tt` checks. |
| Hard aggregate PHP memory admission | KEEP | Host survival requirement. | Preserve Swap-not-RAM and aggregate override checks. |
| Automatic weighted slot distribution | REMOVE | It is an automatic optimizer. New sites start at one ondemand worker; operators make explicit changes. | Preserve current effective limits as desired/manual limits during migration. |
| Historical PSS estimator | MERGE | Replace DB history with baseline plus current PSS that can only raise the estimate. | Existing metrics may be read during migration but are not required after it. |
| SQLite metrics collector/history | REMOVE | Monitoring database is outside installer/basic-ops scope. | Explicitly disable timer; retain units/database until manual cleanup. |
| Terminal dashboard | REMOVE | Depends entirely on historical metrics and embedded curses UI. | Command warns with replacement `status/audit/capacity` during compatibility period. |
| Historical report/analyze | REMOVE | Monitoring/reporting product surface. | No data deletion; document standard OS/monitoring alternatives. |
| Automatic PHP tuner | REMOVE | Hidden policy decisions and cross-coupling exceed Core value. | Reinterpret `tuning.v1` as manual worker state; do not discard limits. |
| Manual PHP workers | KEEP | Explicit operator intent with host-wide admission is a Core capacity need. | Adopt effective v10 limits; never silently clamp or increase. |
| OPcache conservative baseline | KEEP | PHP requires a sensible install default and capacity must reserve effective OPcache. | Preserve administrator and v10 managed values. |
| OPcache runtime dashboard/set workflow | DEPRECATE then EXTERNALIZE | Dedicated tuning UI is outside Core. `capacity` reports effective memory only. | Keep compatibility reader; do not remove INI/state or reload FPM automatically. |
| Shared loopback Redis service | KEEP | Small common host baseline; WordPress integration remains opt-in. | Preserve auth and existing DB assignments. |
| Redis Object Cache plugin automation | EXTERNALIZE | Plugin install/drop-in/config semantics belong to the plugin/operator. | Preserve existing enabled sites and constants; no automatic disable. |
| Private per-site Redis | DEPRECATE then EXTERNALIZE | Per-site services, secrets, sockets and budgets create a mini service orchestrator. | Keep existing services untouched until explicit site migration is reviewed. |
| Redis secret rotation | KEEP temporarily | Still needed to recover safely from a leaked shared v10 credential. | Continue redacted, rollback-capable rotation while v10 shared-auth deployments exist. |
| FastCGI transport | KEEP | Required PHP request path. Retain per-site Unix-socket `fastcgi_pass`, required parameters, compatible timeouts/buffers, and effective FPM/FastCGI validation. | Preserve `try_files`, socket routing and validated transport semantics. |
| FastCGI Page Cache Lite | KEEP optional | Default off; explicit per-site on/off/manual clear; one conservative WordPress bypass set plus WooCommerce rules only for sites explicitly marked WooCommerce. No plugin discovery or cache tuning. | Reuse compatible v10 `page-cache` state; preserve custom exclusions outside Lite ownership. |
| Cache invalidation MU plugin/timer | REMOVE | Application event intelligence and hidden background work. | Explicit migration disables timer/plugin only with confirmation; keep files/data otherwise. |
| Manual page-cache clear | KEEP | A Lite cache without automatic invalidation needs an explicit bounded clear operation. | Clear only the selected site's owned FastCGI cache root after path validation. |
| Arbitrary cache exclusions and object/OPcache clear orchestration | EXTERNALIZE | Plugin routes and non-page caches have different owners and safety semantics. | Preserve existing custom Nginx includes; warn and do not delete. |
| Cloudflare real-IP trust | KEEP optional | Correct client IP is required for logs and rate limits behind the proxy. | Current implementation already avoids DNS/API/APO/cache control. |
| Cloudflare CIDR updater | KEEP optional | Stale trust ranges create correctness/security risk; oneshot timer is justified only when enabled. | Preserve opt-in state; no API token. |
| Cloudflare API/DNS/APO/purge | REMOVE/N/A | Not implemented in 10.0.4 and must not be added. | None. |
| Nginx unknown-Host/security/file guards | KEEP | Broadly compatible, high-value infrastructure baseline. | Preserve custom includes and current site routing. |
| Login POST rate limiting | KEEP optional | Protects CPU/auth surface and relies on verified real IP. | Preserve explicit site state; never enable globally. |
| XML-RPC toggle | KEEP optional | Small infrastructure security control with compatibility-first default enabled. | Preserve each explicit value. |
| HSTS control | DEPRECATE then EXTERNALIZE | CDN/subdomain ownership makes a universal host policy risky. | Continue rendering explicit v10 state for one major; never remove on apply. |
| Strict header profile | DEPRECATE then EXTERNALIZE | Can break iframe/payment/integration behavior and is easy in custom Nginx includes. | Preserve explicit v10 policy until confirmed migration. |
| Local verified backup | KEEP | Core recoverability requirement. | Preserve layout and no-deletion default. |
| Disposable DB restore drill | MERGE | Valuable deep verification; expose as `backup verify --deep`. | Existing `backup drill` becomes a deprecation alias. |
| Daily wp-shell backup timer | DEPRECATE then EXTERNALIZE | Scheduling/retention should be operator-owned; backup commands remain. | Do not silently disable; explicit migration must acknowledge replacement schedule. |
| Encrypted remote backup orchestration | DEPRECATE then EXTERNALIZE | Restic/rclone/provider snapshot tooling is better suited to off-host retention. | Detect configured remotes and block silent behavior loss; preserve policy/files. |
| Conservative restore | KEEP | Necessary to make local backups operationally useful. | Redesign only in S4 after simplification review. |
| Persistent multi-state restore transaction | REMOVE from proposal | High runtime/state/test complexity for a Shell-level cross-store protocol. | PR #5 is not part of the 10.0.4 baseline and must not be merged as v11 foundation. |
| System WP-Cron | KEEP optional | Small, explicit and avoids request-triggered Cron. | Preserve prior-value and no-duplicate behavior. |
| Action Scheduler inspection | EXTERNALIZE | WooCommerce/application-level queue semantics. | Remove from general audit; use WooCommerce tooling when installed. |
| Nested staging management | EXTERNALIZE | Creation, DB isolation, licensing and application behavior belong to staging tooling. | Preserve Nginx custom file and WordPress constants; no automatic cleanup. |
| Bulk WordPress/plugin/theme updates | EXTERNALIZE | High application compatibility risk; not basic VPS operation. | Keep a temporary warning alias; never invoke automatically. |
| Strict WordPress core verify/repair | KEEP | High data-integrity/security value and plugin-independent. | Preserve backup-before-repair and ZIP/checksum rules. |
| SSH/UFW explicit hardening | KEEP optional | Minimal host security with lockout guards. | Preserve explicit confirmations and validation. |
| Fail2ban SSH jail | KEEP | Small validated baseline; not Web visitor blocking. | Preserve only SSH jail. |
| logrotate/Certbot hook | KEEP | Basic host/site operations. | Managed through install/apply. |
| unattended-upgrades management | EXTERNALIZE | Native OS policy varies by administrator and third-party repositories. | Audit/report only; never disable an existing setup. |
| AIDE management | EXTERNALIZE | Separate host integrity product and schedule. | Preserve existing config/Cron; no silent removal. |
| Postfix external-mail mutation | EXTERNALIZE | Mail architecture belongs to the chosen provider/MTA. | Preserve existing loopback configuration and host policy. |

## Complete top-level command classification

| Current command | Decision | v11 destination / compatibility behavior |
|---|---|---|
| `wp-shell` | KEEP | Smaller context-aware menu containing only Core commands. |
| `wp-shell --help` | KEEP | Concise Core help; deprecated aliases in a separate section. |
| `wp-shell --version` | KEEP | No state initialization. |
| `wp-shell install` | KEEP | Install/repair Core baseline only; no metrics/backup timer. |
| `wp-shell dashboard` | REMOVE | v11 compatibility warning points to `status`, `audit`, and `capacity`. |
| `wp-shell audit` | KEEP | Read-only host/site/config/capacity audit. |
| `wp-shell status` | KEEP | Compact current-state output only. |
| `wp-shell dry-run apply` | KEEP | Keep familiar safe planning form; it may also be documented as `apply --dry-run`. |
| `wp-shell apply --confirm` | KEEP | Narrow to Core managed configuration and preserve transactions. |
| `wp-shell rollback [ID] --confirm` | KEEP | Configuration rollback only; never described as content/database rollback. |
| `wp-shell report RANGE` | REMOVE | Historical reporting leaves Core. |
| `wp-shell analyze RANGE` | REMOVE | Historical analysis leaves Core. |
| `wp-shell tune --apply ...` | REMOVE | Replaced by explicit host-wide capacity review and manual worker setting. |
| `wp-shell opcache status [VERSION]` | MERGE | Effective capacity is included in `wp-shell capacity`; compatibility alias warns. |
| `wp-shell opcache set ...` | DEPRECATE/EXTERNALIZE | Preserve existing state; no new Core tuning UI. |
| `wp-shell mariadb audit` | KEEP | Same read-only effective/runtime/definition audit. |
| `wp-shell mariadb migrate-legacy --confirm` | KEEP | Same conservative transactional migration. |
| `wp-shell site ...` | KEEP | Primary lifecycle namespace. |
| `wp-shell metrics ...` | REMOVE | Explicit migration handles timer; data retained. |
| `wp-shell list` | DEPRECATE | Alias to `site list` for v11; remove no earlier than v12. |
| `wp-shell add-site` | DEPRECATE | Alias to `site add`. |
| `wp-shell deploy DOMAIN` | DEPRECATE | Alias to `site deploy DOMAIN`. |
| `wp-shell import` | DEPRECATE | Alias to `site import`. |
| `wp-shell backup-all` | KEEP | Core local backup command. |
| `wp-shell backup ...` | KEEP | Local backup/verification namespace; remote subcommand is externalized. |
| `wp-shell restore DOMAIN BACKUP` | KEEP | S4 conservative confirmed restore. |
| `wp-shell optimize --confirm` | DEPRECATE | Alias to `apply --confirm`, warning in v11, remove in v12. |
| `wp-shell rotate-redis-secret` | KEEP temporarily | Security recovery for v10 shared-auth hosts; advanced help only. |
| `wp-shell cloudflare ...` | KEEP optional | Real-IP trust only; no broader Cloudflare features. |
| `wp-shell security-scan` | MERGE/DEPRECATE | Alias to `audit --strict`; keep exit-status compatibility for v11. |
| `wp-shell system ...` | MIXED | Subcommands classified below; avoid a generic server panel. |
| `wp-shell cron-run DOMAIN` | REMOVE | Unused legacy internal route; current Cron runs WP-CLI directly. |
| `wp-shell ops run` | REMOVE | Cache-invalidation timer worker leaves with cache-auto. |
| `wp-shell install-backup-timer` | DEPRECATE/EXTERNALIZE | Existing timer preserved; new installs do not create it. |
| `wp-shell migrate` | KEEP/REPURPOSE | Becomes explicit `migrate v10 --confirm`; must not remain a no-op success message. |
| `wp-shell legacy-vps ...` | KEEP for v11 | Internal compatibility wrapper target; warning, then route supported operations. |
| `wp-shell legacy-single ...` | KEEP for v11 | Internal compatibility wrapper target; warning, then route unambiguous site operations. |

## Metrics commands

| Current command | Decision | Notes |
|---|---|---|
| `metrics collect` | REMOVE | No historical collector in v11. |
| `metrics install` | REMOVE | Explicit migration disables the old timer; it does not delete units/data. |
| `metrics status` | REMOVE | `status` reports whether deprecated units still exist/are active. |

## Site namespace and actions

| Current command/action | Decision | v11 destination / compatibility behavior |
|---|---|---|
| `site add` | KEEP | New site starts with one ondemand worker and explicit optional choices only. |
| `site list` | KEEP | Show domain, path, PHP, mode, effective workers, and compatibility flags. |
| `site status [DOMAIN]` | KEEP | Current health only; domain form becomes canonical `site DOMAIN status`. |
| `site deploy DOMAIN` | KEEP | Idempotent Core deploy/repair with capacity preflight. |
| `site import` | KEEP | Preserve in-memory-first admission and no-partial-persist behavior. |
| `site DOMAIN status` | KEEP | Canonical per-site status. |
| `site DOMAIN info` | MERGE | `site DOMAIN status --verbose`. |
| `site DOMAIN summary` | MERGE | `site DOMAIN status --verbose`; credentials are never reprinted. |
| `site DOMAIN core-verify` | KEEP | May be spelled `site DOMAIN core verify`. |
| `site DOMAIN core-repair` | KEEP | May be spelled `site DOMAIN core repair --confirm`; backup remains mandatory. |
| `site DOMAIN isolate` | KEEP | Compatibility migration to mandatory per-site identity. |
| `site DOMAIN redis-isolate` | DEPRECATE/EXTERNALIZE | Status warning only; no new instance creation in v11. |
| `site DOMAIN cron enable` | KEEP | Optional simple system WP-Cron. |
| `site DOMAIN cron disable` | KEEP | Restore recorded prior value and remove only owned Cron file. |
| `site DOMAIN cron status` | KEEP | Current config/schedule state; no queue execution. |
| `site DOMAIN page-cache enable` | KEEP | Enable Page Cache Lite only with `--confirm`; use generic WordPress bypass and explicit WooCommerce extension. |
| `site DOMAIN page-cache disable` | KEEP | Disable the selected site's Lite cache transactionally; keep static browser caching. |
| `site DOMAIN page-cache status` | KEEP | Report effective Nginx cache state and whether generic/WooCommerce bypass profile applies. |
| `site DOMAIN object-cache enable` | EXTERNALIZE | Plugin/operator documentation owns integration. |
| `site DOMAIN object-cache disable` | DEPRECATE | Retain only as safe compatibility escape hatch; do not remove plugin/config automatically. |
| `site DOMAIN object-cache status` | MERGE | Report observed state in site status; do not mutate. |
| `site DOMAIN cache-clear page` | KEEP/MERGE | Canonical replacement becomes `site DOMAIN page-cache clear`; only the owned site cache root is touched. |
| `site DOMAIN cache-clear object|opcache|all` | DEPRECATE/EXTERNALIZE | Object cache and OPcache have different owners; old forms warn and do not become Page Cache Lite behavior. |
| `site DOMAIN cache-auto enable` | REMOVE | No new MU plugin/timer. |
| `site DOMAIN cache-auto disable` | DEPRECATE | Explicitly remove only the owned MU plugin/marker after confirmation. |
| `site DOMAIN cache-auto status` | MERGE | Legacy state warning in site status. |
| `site DOMAIN cache-exclude PATH` | EXTERNALIZE | Preserve existing custom include; manual Nginx/app cache configuration. |
| `site DOMAIN login-limit direct` | KEEP | Rename to `login-limit enable --confirm`; verified IP prerequisite. |
| `site DOMAIN login-limit off` | KEEP | Rename to `login-limit disable --confirm`. |
| `site DOMAIN login-limit status` | KEEP | Read-only. |
| `site DOMAIN staging configure ...` | EXTERNALIZE | No new staging mutation in v11. |
| `site DOMAIN staging status` | DEPRECATE | Legacy-state report only. |
| `site DOMAIN hsts enable` | DEPRECATE/EXTERNALIZE | No new enablement; custom Nginx/CDN ownership. |
| `site DOMAIN hsts disable` | DEPRECATE | Explicit, because silent removal is unsafe. |
| `site DOMAIN hsts status` | MERGE | Legacy status flag. |
| `site DOMAIN xmlrpc enable` | KEEP | Explicit compatibility action. |
| `site DOMAIN xmlrpc disable` | KEEP | Explicit security action; never default. |
| `site DOMAIN xmlrpc status` | KEEP | Read-only. |
| `site DOMAIN headers strict` | DEPRECATE/EXTERNALIZE | Do not add compatibility-sensitive global policy. |
| `site DOMAIN headers compatible` | DEPRECATE | Explicit path out of prior managed policy. |
| `site DOMAIN headers status` | MERGE | Legacy status flag. |
| `site DOMAIN nginx-apply` | MERGE | Internal step of `site deploy`; an advanced `--config-only` form may remain if tests justify it. |
| `site DOMAIN maintenance on` | KEEP advanced | Recovery/operator escape hatch; root-owned marker only. |
| `site DOMAIN maintenance off` | KEEP advanced | Require confirmation if a restore-failure receipt exists. |
| `site DOMAIN maintenance status` | MERGE | Included in site status. |
| `site DOMAIN backup` | MERGE | Canonical `backup DOMAIN`. |
| `site DOMAIN backups` | MERGE | `backup list DOMAIN` or `backup DOMAIN --list`; keep one spelling only. |
| `site DOMAIN restore BACKUP` | MERGE | Canonical top-level `restore DOMAIN BACKUP --confirm`. |
| `site DOMAIN update --confirm-updates` | EXTERNALIZE | WP-CLI/plugin-specific maintenance workflow. |
| `site DOMAIN restart` | EXTERNALIZE | PHP version service affects multiple sites; use audited service operations, not site fiction. |

## Backup commands

| Current command | Decision | v11 destination / compatibility behavior |
|---|---|---|
| `backup DOMAIN` | KEEP | Local verified backup. |
| `backup verify DOMAIN [ID]` | KEEP | Fast checksum/archive/manifest verification. |
| `backup drill DOMAIN [ID]` | MERGE | `backup verify DOMAIN [ID] --deep`; old spelling warns for v11. |
| `backup remote DOMAIN status` | DEPRECATE | Report legacy ownership and migration blocker. |
| `backup remote DOMAIN crypt:PATH` | EXTERNALIZE | No new remote configuration. |
| `backup remote DOMAIN off` | DEPRECATE | Explicitly stop v10 remote upload only after replacement is acknowledged; never delete remote data. |

## Cloudflare real-IP commands

The 10.0.4 Cloudflare implementation already stops at verified real-IP handling; it does not manage DNS, APO, WAF, purge, or API bans. Therefore these remain optional Core compatibility rather than a Cloudflare control plane.

| Current command | Decision | Notes |
|---|---|---|
| `cloudflare enable --confirm` | KEEP | Verified official CIDRs and optional updater only. |
| `cloudflare disable --confirm` | KEEP | Remove only owned trust/updater after Nginx validation. |
| `cloudflare update` | KEEP | Manual refresh and timer target. |
| `cloudflare status` | KEEP | Read-only current trust/unit state. |
| `cloudflare check SOURCE CLAIMED` | KEEP | Proves trusted versus forged header behavior. |

## System subcommands

| Current command | Decision | v11 destination / compatibility behavior |
|---|---|---|
| `system audit` | MERGE | Top-level `audit`. |
| `system updates enable --confirm` | EXTERNALIZE | Report status and link to Ubuntu guidance; do not own policy. |
| `system logs install` | MERGE | Core install/apply owns wp-shell logrotate. |
| `system wp-cli verify` | MERGE | Core install verifies signed WP-CLI; audit reports version/provenance. |
| `system ssh apply --confirm-lockout-risk` | KEEP optional | Explicit minimal hardening with active-session/key checks and `sshd -t`. |
| `system firewall apply --confirm` | KEEP optional | UFW default-deny/SSH limit/80/443 with no deletion of unknown rules. |
| `system aide apply --confirm` | EXTERNALIZE | Preserve existing configuration and Cron. |
| `system mail external --confirm-external-mail` | EXTERNALIZE | Preserve current Postfix configuration; mail provider/MTA docs own it. |

## Normal operator surface after deprecation aliases expire

The normal v11 operator should need approximately these 18 forms:

```text
wp-shell install
wp-shell status
wp-shell audit
wp-shell capacity
wp-shell dry-run apply
wp-shell apply --confirm
wp-shell rollback [ID] --confirm
wp-shell migrate v10 --confirm
wp-shell site list
wp-shell site add
wp-shell site import
wp-shell site deploy DOMAIN
wp-shell site DOMAIN status
wp-shell site DOMAIN workers N --confirm
wp-shell backup DOMAIN
wp-shell backup-all
wp-shell backup verify DOMAIN [ID] [--deep]
wp-shell restore DOMAIN BACKUP_ID --confirm
```

MariaDB legacy, XML-RPC/login protection, Cloudflare real-IP, SSH/UFW, core repair, Cron, and recovery maintenance remain supported but live in advanced help rather than the common path.
