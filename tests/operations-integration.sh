#!/usr/bin/env bash
# Run only in a disposable root container.
# shellcheck disable=SC1091,SC2034,SC2317,SC2329
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || exit 1
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/wp-shell-operations-test.XXXXXX)"
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
export WP_SHELL_TEST_ROOT_WRITES=yes
source "$repo_root/wp-shell.sh"
trap 'printf "Operations integration failed at line %s.\n" "$LINENO" >&2; if [[ -s "$test_root/isolation-failure.log" ]]; then tail -80 "$test_root/isolation-failure.log" >&2; fi' ERR
install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR" "$STATE_DIR"
memory_mb() { printf '3832'; }
SITE_COUNT=2
for i in 1 2; do
    domain="ops$i.example.com"
    SITE_DOMAINS[i]="$domain"
    SITE_PRIMARY_DOMAINS[i]="$domain"
    SITE_PHP_VERSIONS[i]=8.3
    SITE_WOOCOMMERCE[i]=no
    SITE_REDIS_DATABASES[i]="$((i-1))"
    SITE_MODES[i]=managed
    SITE_PATHS[i]="/var/www/$domain/public"
    create_site_identity "$domain"
    create_site_directories "$domain" "${SITE_PATHS[$i]}"
    printf '<?php\n' > "${SITE_PATHS[$i]}/wp-config.php"
    printf 'test\n' > "${SITE_PATHS[$i]}/index.html"
    set_site_permissions "$domain"
done
first_user="$(site_run_user ops1.example.com)"
second_user="$(site_run_user ops2.example.com)"
if runuser -u "$first_user" -- test -r /var/www/ops2.example.com/public/wp-config.php; then exit 1; fi
if runuser -u "$second_user" -- test -w /var/www/ops1.example.com/public/index.html; then exit 1; fi
runuser -u www-data -- test -r /var/www/ops1.example.com/public/index.html
[[ "$(stat -c '%a %U %G' /var/www/ops1.example.com/public/wp-config.php)" == "640 root $(id -gn "$first_user")" ]]

legacy_core_failure=no
systemctl() {
    printf '%s\n' "$*" >> "$test_root/service-calls"
    if [[ "$*" == enable\ --now\ wp-shell-redis-* ]]; then
        local unit="${3%.service}" run_user run_group
        run_user="$(sed -n 's/^User=//p' "/etc/systemd/system/$unit.service")"
        run_group="$(sed -n 's/^Group=//p' "/etc/systemd/system/$unit.service")"
        install -d -o "$run_user" -g "$run_group" -m 0750 "/run/$unit" "/var/lib/$unit"
        if ! runuser -u "$run_user" -g "$run_group" -- redis-server "/etc/wp-shell-redis/${unit#wp-shell-redis-}.conf" --daemonize yes --pidfile "/run/$unit/test.pid" --logfile "/run/$unit/test.log"; then
            [[ ! -f "/run/$unit/test.log" ]] || tail -n 40 "/run/$unit/test.log" >&2
            return 1
        fi
    fi
    return 0
}
install_self() { :; }
backup_site() { printf 'Safety backup requested\n' >> "$test_root/backup-calls"; }
site_wp_cli() {
    local domain="$1" action="$2" config_file key value secret
    config_file="$(site_wp_path "$1")/wp-config.php"
    shift 2
    case "$action $*" in
        'plugin is-active redis-cache') : ;;
        'redis status')
            secret="$(site_policy_value "$domain" redis-secret)"
            [[ "$(REDISCLI_AUTH="$secret" runuser -u "$(site_run_user "$domain")" -- redis-cli -s "$(site_redis_socket "$domain")" ping)" == PONG ]]
            printf 'Status: Connected\n'
            ;;
        'config get DISABLE_WP_CRON') printf 'false\n' ;;
        config\ set\ *)
            key="$2"; value="$3"
            sed -i "/define( '$key',/d" "$config_file"
            printf "define( '%s', '%s' );\n" "$key" "$value" >> "$config_file"
            ;;
        'cron event run --due-now') printf 'cron ran\n' >> "$test_root/cron-calls" ;;
        'core is-installed') [[ "$legacy_core_failure" != yes ]] ;;
        *) printf 'Unexpected fixture WP-CLI call: %s\n' "$action $*" >&2; return 1 ;;
    esac
}
# Simulate an existing shared-UID site before its explicit migration.
set_site_policy ops2.example.com user www-data
set_site_permissions ops2.example.com
install -d -o www-data -g www-data -m 0700 /var/www/ops2.example.com/.wp-shell
install -d -m 0755 /etc/nginx/sites-available
printf '# .wp-shell-maintenance\n' > /etc/nginx/sites-available/ops2.example.com
configure_redis
configure_php
php-fpm8.3 -D
redis-server /etc/redis/wp-shell.conf --supervised no --daemonize yes --pidfile "$test_root/shared.pid" --logfile "$test_root/shared.log"
cleanup_operations_test() {
    local pid_file attempt
    for pid_file in "$test_root/shared.pid" /run/wp-shell-redis-*/test.pid /run/php/php8.3-fpm.pid; do
        [[ -f "$pid_file" ]] || continue
        kill "$(<"$pid_file")" 2>/dev/null || true
    done
    if [[ -n "${db_pid:-}" ]]; then
        kill "$db_pid" 2>/dev/null || true
        wait "$db_pid" 2>/dev/null || true
    fi
    for ((attempt=0; attempt<10; attempt++)); do
        rm -rf -- "$test_root" 2>/dev/null || true
        [[ -e "$test_root" ]] || break
        sleep 0.1
    done
}
trap cleanup_operations_test EXIT
legacy_pool="/etc/php/8.3/fpm/pool.d/wp-shell-$(site_pool_id ops2.example.com).conf"
legacy_pool_hash="$(sha256sum "$legacy_pool")"
legacy_core_failure=yes
if (isolate_site 2 --yes) > "$test_root/isolation-failure.log" 2>&1; then exit 1; fi
[[ "$(site_run_user ops2.example.com)" == www-data ]]
[[ "$(sha256sum "$legacy_pool")" == "$legacy_pool_hash" ]]
[[ "$(stat -c '%a %U %G' /var/www/ops2.example.com/public/wp-config.php)" == '640 root www-data' ]]
[[ "$(stat -c %U /var/www/ops2.example.com/.wp-shell)" == www-data ]]
[[ ! -e /var/www/ops2.example.com/.wp-shell-maintenance ]]
legacy_core_failure=no
isolate_site 2 --yes
[[ "$(site_run_user ops2.example.com)" == "$second_user" ]]
[[ "$(stat -c '%a %U %G' /var/www/ops2.example.com/public/wp-config.php)" == "640 root $(id -gn "$second_user")" ]]
[[ ! -e /var/www/ops2.example.com/.wp-shell-maintenance ]]
if runuser -u "$first_user" -- test -r /var/www/ops2.example.com/public/wp-config.php; then exit 1; fi
isolate_site_redis 1 64
load_or_create_redis_secret
[[ "$(REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw CONFIG GET maxmemory | tail -n 1)" == "$((127*1048576))" ]]
[[ "$(site_policy_value ops1.example.com redis-mode)" == isolated ]]
site_listing="$(list_sites)"
grep -Eq 'ops1.example.com.*private' <<< "$site_listing"
if runuser -u "$second_user" -- redis-cli -s "$(site_redis_socket ops1.example.com)" ping >/dev/null 2>&1; then exit 1; fi
[[ "$(shared_redis_memory_budget)" == 127 ]]
if (isolate_site_redis 2 128) >/dev/null 2>&1; then exit 1; fi
[[ "$(site_policy_value ops2.example.com redis-mode shared)" == shared ]]

site_cron_action ops1.example.com enable
grep -q "DISABLE_WP_CRON', 'true'" /var/www/ops1.example.com/public/wp-config.php
grep -Fq '*/5 * * * *' "/etc/cron.d/wp-shell-$(site_pool_id ops1.example.com)"
grep -Fq "$first_user" "/etc/cron.d/wp-shell-$(site_pool_id ops1.example.com)"
[[ ! -e "$test_root/cron-calls" ]]
site_cron_action ops1.example.com disable
grep -q "DISABLE_WP_CRON', 'false'" /var/www/ops1.example.com/public/wp-config.php
[[ ! -e "/etc/cron.d/wp-shell-$(site_pool_id ops1.example.com)" ]]

site_cache_auto ops1.example.com enable
php -l /var/www/ops1.example.com/public/wp-content/mu-plugins/wp-shell-cache.php >/dev/null
rm -f /var/www/ops1.example.com/.wp-shell/cache-dirty
runuser -u "$first_user" -- php -r 'define("ABSPATH", "/var/www/ops1.example.com/public/"); function add_action() {} require ABSPATH . "wp-content/mu-plugins/wp-shell-cache.php"; wp_shell_signal_page_change();'
[[ -f /var/www/ops1.example.com/.wp-shell/cache-dirty ]]
printf 'old page\n' > /var/www/ops1.example.com/cache/fixture
run_operations
[[ ! -e /var/www/ops1.example.com/cache/fixture && ! -e /var/www/ops1.example.com/.wp-shell/cache-dirty ]]

# Verify the signed WP-CLI download before any PHAR execution.
install_wp_cli --verify
php /usr/local/bin/wp --info >/dev/null

# Real database drill, including a client-command escape attempt.
install -d -o mysql -g mysql -m 0755 /run/mysqld
mariadbd --user=mysql --skip-networking --pid-file=/run/mysqld/wp-shell-drill.pid --log-error=/tmp/wp-shell-drill-db.log &
db_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    if mariadb -e 'SELECT 1' >/dev/null 2>&1; then break; fi
    sleep 0.1
done
mkdir -p "$test_root/drill/files"
printf '<?php\n' > "$test_root/drill/files/wp-config.php"
tar -czf "$test_root/drill/files.tar.gz" -C "$test_root/drill/files" .
printf 'CREATE TABLE fixture (id INT); INSERT INTO fixture VALUES (1);\n' | gzip > "$test_root/drill/database.sql.gz"
backup_restore_drill ops1.example.com "$test_root/drill"
printf '\\! touch /tmp/wp-shell-drill-escape\n' | gzip > "$test_root/drill/database.sql.gz"
if (backup_restore_drill ops1.example.com "$test_root/drill") >/dev/null 2>&1; then exit 1; fi
[[ ! -e /tmp/wp-shell-drill-escape ]]
[[ "$(mariadb -NBe "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name LIKE 'drill_%';")" == 0 ]]
[[ "$(mariadb -NBe "SELECT COUNT(*) FROM mysql.user WHERE User LIKE 'drill_%';")" == 0 ]]
printf 'UID isolation/migration/rollback, private Redis socket/budget, cron gating, cache events, signed WP-CLI and isolated restore drill tests passed.\n'
