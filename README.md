# wp-shell

`wp-shell` is a lightweight WordPress VPS deployment and operations tool for Ubuntu. It is designed to cover the practical single-server workflows commonly handled by Cloudways or SpinupWP, without a web control panel or its permanent resource overhead.

- One canonical script: `wp-shell.sh` v9.0.0
- Supported systems: Ubuntu 22.04 and 24.04 LTS
- Architectures: x86_64 and aarch64
- Project: <https://github.com/hwc0212/wp-shell>
- Author: <https://huwencai.com>

The previous `wp-vps-manager.sh` and `deploy-single-wordpress.sh` filenames remain as small compatibility wrappers. New installations should use `wp-shell.sh`.

> `wp-shell` installs packages and changes Nginx, PHP-FPM, MariaDB, Redis, Fail2ban, UFW, Certbot, logrotate, and systemd configuration. Test it on a disposable server first and keep an off-server backup before adopting an existing production VPS.

## What v9 provides

- Repeatable single-site and multi-site deployment through one command.
- A separate PHP-FPM pool, socket, status socket, process limit, and PHP log for every site.
- Per-site FastCGI cache, Redis database, database credentials, logs, and backups.
- A local SQLite metrics store and a one-minute systemd collector.
- An English, ASCII-only, `htop`-style terminal dashboard designed to fit one SSH screen.
- Per-domain traffic, latency, cache, PHP, disk, TLS, HTTP, and backup visibility.
- Evidence-based resource analysis and guarded PHP-FPM tuning.
- Safe migration from the v8 multi-site and v2 single-site configuration formats.
- Atomic Nginx validation and rollback, checksummed backups, and pre-restore safety backups.
- No web panel, panel database, telemetry service, or externally exposed metrics endpoint.

## Requirements

- Ubuntu 22.04 or 24.04 LTS
- At least 1GB RAM
- At least 8GB free space on `/`
- Root or sudo access
- DNS already pointing to the VPS
- TCP 80 and 443 reachable from the internet

The default site-count guard is intentionally conservative:

| RAM | Maximum managed sites |
|---|---:|
| 1GB to 2GB | 1 |
| 2GB to 4GB | 2 |
| 4GB to 8GB | 4 |
| 8GB and above | 8 |

Traffic, plugins, themes, WooCommerce, and uncached requests can reduce the practical capacity substantially.

## Install

```bash
wget https://raw.githubusercontent.com/hwc0212/wp-shell/main/wp-shell.sh
chmod +x wp-shell.sh
sudo ./wp-shell.sh install
```

The setup wizard collects each domain, canonical hostname, PHP version, WordPress administrator, optional `www`, and optional WooCommerce choice. It then installs and configures the stack, obtains certificates, deploys WordPress, installs backup and metrics timers, and optionally configures UFW.

The installed command is:

```bash
sudo wp-shell --version
sudo wp-shell --help
```

## Terminal dashboard

Open the dashboard over SSH:

```bash
sudo wp-shell dashboard
```

It refreshes in place and adjusts columns to the current terminal width and height. It does not scroll continuously like a log viewer.

| Key | View or action |
|---|---|
| `F1` or `1` | Overview |
| `F2` or `2` | Traffic |
| `F3` or `3` | Resources |
| `F4` or `4` | Operations |
| `F5` or `5` | Alerts |
| Arrow keys or `h/j/k/l` | Change view or selected site |
| `r` | Refresh immediately |
| `q` | Quit |

The dashboard uses a compact header for CPU, memory, load, swap, and disk, followed by one site per row and a fixed shortcut footer. A terminal smaller than 64x14 receives a resize message instead of a broken layout.

For scripts, narrow terminals, or saved SSH output, use the plain report:

```bash
sudo wp-shell report 24h
sudo wp-shell report 7d
```

## Metrics and privacy

The local collector is installed as `wp-shell-metrics.timer` and runs once per minute:

```bash
systemctl status wp-shell-metrics.timer
sudo wp-shell metrics status
sudo wp-shell metrics collect
```

Collected system fields include CPU, load, available memory, swap, root disk usage, and network byte counters. Per-site fields include:

- Requests and HTTP 2xx, 4xx, and 5xx totals
- Response bytes, average latency, and P95 latency
- FastCGI cache hits, misses, bypasses, and stale responses
- PHP-FPM active/idle processes, queue, saturation counter, and RSS
- Site files, cache, logs, and backup sizes
- HTTP response, TLS days remaining, and latest backup age
- Shared MariaDB connection/slow-query counters and Redis memory/cache counters

Operational data is stored only on the VPS:

```text
/var/lib/wp-shell/metrics.sqlite3
```

Raw samples are retained for 30 days. The structured Nginx access format intentionally excludes client IP addresses, cookies, referrers, user agents, and query strings. It retains the URI path because route-level behavior is useful for diagnosing WordPress and WooCommerce workloads.

## Resource analysis and tuning

Use collected evidence after the server has handled representative traffic:

```bash
sudo wp-shell analyze 7d
sudo wp-shell analyze 14d
sudo wp-shell tune --apply
```

The initial budget reserves memory for the operating system, then assigns approximately 30% to MariaDB, 5% to Redis with a 32-512MB limit, and a bounded remainder to PHP-FPM. PHP capacity is estimated at roughly 96MB per process. WooCommerce sites receive twice the initial pool weight of standard sites.

Automatic tuning is deliberately narrow:

- It changes only per-site PHP-FPM child limits.
- It requires at least 1,000 samples and at least 20% observed memory headroom.
- An increase requires a PHP queue or pool saturation signal.
- A decrease requires approximately 14 days of low peak utilization.
- One change is limited to about 20%, with a range of 2-50 children.
- Recommendations are shown before application unless `--yes` is supplied.
- Overrides are stored in `/etc/wp-shell/tuning.v1` and can be reviewed or removed.

MariaDB and Redis findings remain advisory because aggregate counters alone are not enough to safely rewrite their memory settings automatically.

## Site commands

```bash
sudo wp-shell site add
sudo wp-shell site list
sudo wp-shell site status
sudo wp-shell site status example.com
sudo wp-shell site deploy example.com
sudo wp-shell site import
```

Each managed site also receives a convenience wrapper:

```bash
manage-example.com status
manage-example.com info
manage-example.com cache-clear
manage-example.com backup
manage-example.com backups
manage-example.com restore 20260817-020000
manage-example.com update
manage-example.com restart
```

Global equivalents remain available:

```bash
sudo wp-shell backup example.com
sudo wp-shell backup-all
sudo wp-shell restore example.com 20260817-020000
sudo wp-shell optimize
sudo wp-shell security-scan
```

`site import` registers detected WordPress paths as `imported`. It does not immediately replace their Nginx, TLS, database, or Redis configuration. Running `site deploy DOMAIN` explicitly transfers that site to managed mode.

## Site layout

Every standard site is contained under one domain directory:

```text
/var/www/DOMAIN/public/       WordPress document root
/var/www/DOMAIN/logs/         Nginx and PHP-FPM logs
/var/www/DOMAIN/cache/        Nginx FastCGI cache
/var/www/DOMAIN/backups/      Local backup archives
```

Backups are outside the public document root and use root-only permissions. Each timestamped backup contains:

```text
files.tar.gz
database.sql.gz
manifest.txt
SHA256SUMS
```

The `wp-shell-backup.timer` runs daily around 02:00 with a randomized delay. Backups default to 14-day retention:

```bash
systemctl status wp-shell-backup.timer
sudo BACKUP_RETENTION_DAYS=30 wp-shell backup-all
```

Local backups do not protect against complete VPS or disk loss. Replicate `/var/www/*/backups` to object storage or another server and test restores regularly.

## Configuration and installed files

```text
/etc/wp-shell/sites.v3                    Non-executable site inventory
/etc/wp-shell/databases/                  Per-site database credentials
/etc/wp-shell/redis.secret                Redis password
/etc/wp-shell/tuning.v1                   Optional PHP-FPM overrides
/etc/nginx/conf.d/wp-shell-log-format.conf
/usr/local/sbin/wp-shell                  Installed manager
/usr/local/bin/wp-shell                   Command symlink
/usr/local/bin/manage-DOMAIN              Site wrapper
/var/lib/wp-shell/metrics.sqlite3         Local metrics database
/var/log/wp-shell/                        Deployment and command logs
```

Secrets and configuration data are stored with `0600` permissions. Generated WordPress administrator credentials are written once to `/root/wordpress-credentials-DOMAIN.txt`; move them into a password manager and remove the plaintext file after first login.

## Upgrade from the previous scripts

Download v9 and run any normal command:

```bash
sudo ./wp-shell.sh site list
```

If `/etc/wp-shell/sites.v3` does not exist, v9 safely reads these non-executable legacy formats:

```text
/etc/wp-vps-manager/sites.v2
/etc/wp-single-deploy/site.v2
```

It merges the inventories, preserves database and Redis secret files, writes the v3 configuration, and copies the original configuration directories to:

```text
/etc/wp-shell/migration-backup/TIMESTAMP/
```

Legacy files are not deleted. Old backups under `/var/backups/wp-shell/DOMAIN` and `/var/backups/wp-shell-single/DOMAIN` are copied without overwriting newer archives when the site backup storage is first used. Old cache content under `/var/cache/nginx/DOMAIN` is cleared during the transition but new cache data lives only under `/var/www/DOMAIN/cache`.

The old command names continue to work through wrappers, but documentation and new automation should use `wp-shell`.
When the unified backup timer is installed, the two legacy backup timers are disabled to prevent duplicate daily archives; their unit files are left in place for audit or manual removal.

## Security notes

- Redis listens only on loopback, uses protected mode and a generated password.
- Database and Redis credentials are never embedded in site wrapper commands.
- Nginx configuration must pass `nginx -t`; a failed replacement is rolled back.
- PHP-FPM status sockets are local Unix sockets and are not exposed by Nginx.
- `wp-config.php` is set to `0640`, and WordPress file editing is disabled.
- UFW preserves existing rules and allows the detected SSH port before enabling HTTP/HTTPS rules.
- Fail2ban uses validated SSH and Nginx authentication jails.
- TLS 1.2/1.3, HSTS, and standard security headers are enabled.
- Site logs rotate daily and retain 14 compressed rotations.

## Troubleshooting

```bash
sudo wp-shell site status example.com
sudo wp-shell metrics status
nginx -t
systemctl status nginx mariadb redis-server php8.3-fpm
systemctl status wp-shell-metrics.timer wp-shell-backup.timer
certbot certificates
ls -lt /var/log/wp-shell/
tail -f /var/www/example.com/logs/nginx-error.log
tail -f /var/www/example.com/logs/php-error.log
```

If certificate issuance fails, verify both DNS names selected during setup:

```bash
getent ahosts example.com
getent ahosts www.example.com
ss -ltnp | grep -E ':(80|443)\b'
ufw status verbose
```

## Development and verification

```bash
bash tests/static-checks.sh
bash tests/config-roundtrip.sh
bash tests/render-nginx.sh
bash tests/storage-layout.sh
bash tests/metrics-roundtrip.sh
bash tests/dashboard-smoke.sh
```

GitHub Actions additionally runs ShellCheck and validates generated Nginx, MariaDB, Redis, and PHP-FPM configuration inside Ubuntu 24.04 containers.

## Scope

The lack of a web control panel is intentional. `wp-shell` focuses on one Ubuntu VPS and does not claim to provide clustering, high availability, database replication, cross-server migration, site cloning, cloud backup upload, or a hosted control plane.

## License

MIT
