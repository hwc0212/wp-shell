#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2031,SC2032,SC2034,SC2317,SC2329
set -Eeuo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
source "$repo_root/wp-shell.sh"
install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR" "$STATE_DIR"

# Non-TTY logging must not abort cleanup while handling a previous failure.
if (trap 'log_message WARNING "Rollback log fixture"; printf "cleanup-finished\n"' EXIT; exit 1) > "$test_root/trap-log" 2>&1; then exit 1; fi
grep -q 'Rollback log fixture' "$test_root/trap-log"
grep -q 'cleanup-finished' "$test_root/trap-log"

SITE_COUNT=2
SITE_DOMAINS[1]=bad.example.com
SITE_DOMAINS[2]=good.example.com
SITE_PHP_VERSIONS[1]=8.3
SITE_PHP_VERSIONS[2]=8.3
SITE_PHP_MAX_CHILDREN[1]=4
SITE_PHP_MAX_CHILDREN[2]=4
site_wp_path() { printf '%s/public/%s' "$test_root" "$1"; }
site_backup_dir() { printf '%s/backups/%s' "$test_root" "$1"; }
site_cache_dir() { printf '%s/cache/%s' "$test_root" "$1"; }
site_wp_cli_home() { printf '%s/home/%s' "$test_root" "$1"; }
ensure_site_storage() { mkdir -p "$(site_backup_dir "$1")" "$(site_cache_dir "$1")" "$(site_wp_cli_home "$1")"; }
create_mysql_defaults_file() { mktemp "$test_root/mysql.XXXXXX"; }
site_wp_cli() {
    case "$2 $3" in
        'config get') printf 'wp_test' ;;
        'core version') printf '6.8.2' ;;
    esac
}
mariadb-dump() { printf 'CREATE TABLE test (id int);\n'; }
mariadb() { printf '1\n'; }
sha256sum() {
    if [[ "$PWD" == *bad.example.com* && "$*" == 'files.tar.gz database.sql.gz manifest.txt' ]]; then return 1; fi
    command sha256sum "$@"
}
for domain in "${SITE_DOMAINS[@]}"; do
    mkdir -p "$(site_wp_path "$domain")"
    printf '<?php // test\n' > "$(site_wp_path "$domain")/wp-config.php"
done
if (backup_all_sites) > "$test_root/backup-output" 2>&1; then
    printf 'A checksum failure was reported as successful.\n' >&2; exit 1
fi
grep -q 'checksum generation failed' "$test_root/backup-output"
grep -q 'Backup completed:.*good.example.com' "$test_root/backup-output"
[[ -z "$(find "$(site_backup_dir bad.example.com)" -mindepth 1 -maxdepth 1 -type d)" ]]
backup_dir="$(find "$(site_backup_dir good.example.com)" -mindepth 1 -maxdepth 1 -type d)"
verify_backup_directory "$backup_dir" good.example.com
printf 'corrupt\n' >> "$backup_dir/manifest.txt"
if verify_backup_directory "$backup_dir" good.example.com >/dev/null 2>&1; then exit 1; fi
[[ -z "$(find "$test_root" -maxdepth 1 -name 'mysql.*')" ]]

init_metrics_database
now="$(date +%s)"
sqlite3 "$METRICS_DB" <<SQL
WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<1440)
INSERT INTO system_samples SELECT $now-(1440-i)*60,10,1,3832,2000,0,20,0,0 FROM n;
INSERT INTO site_samples(ts,domain,php_active,php_idle,php_queue,php_max_children,php_pss_mb)
SELECT ts,'bad.example.com',4,0,0,4,400 FROM system_samples;
INSERT INTO site_samples(ts,domain,php_active,php_idle,php_queue,php_max_children,php_pss_mb)
SELECT ts,'good.example.com',4,0,0,4,400 FROM system_samples;
INSERT INTO sample_health SELECT ts,'','system',1 FROM system_samples;
INSERT INTO sample_health SELECT ts,domain,'php',1 FROM site_samples;
SQL
read_pool_limit() { printf '4'; }
PHP_TOTAL_BUDGET_MB=1200
build_tuning_recommendations "$test_root/tune"
[[ "$(wc -l < "$test_root/tune")" -eq 1 ]]
grep -q 'bad.example.com|4|5|' "$test_root/tune"
# Both proposed increases combined would require 1250MB: never allow that.
sqlite3 "$METRICS_DB" 'UPDATE system_samples SET cpu_pct=100;'
build_tuning_recommendations "$test_root/tune"
[[ ! -s "$test_root/tune" ]]
sqlite3 "$METRICS_DB" "UPDATE system_samples SET cpu_pct=10; DELETE FROM sample_health WHERE domain='good.example.com';"
build_tuning_recommendations "$test_root/tune"
[[ ! -s "$test_root/tune" ]]
sqlite3 "$METRICS_DB" "INSERT INTO sample_health SELECT ts,domain,'php',1 FROM site_samples WHERE domain='good.example.com';"
PHP_TOTAL_BUDGET_MB=900
build_tuning_recommendations "$test_root/tune"
[[ ! -s "$test_root/tune" ]]
PHP_TOTAL_BUDGET_MB=2000
build_tuning_recommendations "$test_root/tune" 3600
[[ ! -s "$test_root/tune" ]]

# A failed transaction must fail loudly and preserve both rows and cursors.
sqlite3 "$METRICS_DB" 'DELETE FROM system_samples; DELETE FROM site_samples; DELETE FROM sample_health;'
printf '123 12\n' > "$STATE_DIR/cpu.state"
calculate_resource_budget() { :; }
collect_system_sample() {
    printf '999 99\n' > "$METRICS_CURSOR_DIR/cpu.state"
    record_metric_sql "INSERT INTO system_samples VALUES($1,1,1,2000,1000,0,1,0,0);"
}
collect_service_sample() { record_metric_sql 'INSERT INTO missing_table VALUES(1);'; }
collect_site_sample() { :; }
collect_pressure_sample() { :; }
if collect_metrics > "$test_root/collector-output" 2>&1; then exit 1; fi
[[ "$(sqlite3 "$METRICS_DB" 'SELECT COUNT(*) FROM system_samples;')" -eq 0 ]]
[[ "$(<"$STATE_DIR/cpu.state")" == '123 12' ]]
[[ -z "$(find "$STATE_DIR" -maxdepth 1 -name '.sample.*')" ]]

# Cache clears default to pages; no PHP reload/object-cache flush as side effects.
site_wp_cli() { printf 'unexpected WP invocation\n' >&2; return 1; }
php_fpm_service_action() { printf 'unexpected FPM invocation\n' >&2; return 1; }
mkdir -p "$(site_cache_dir good.example.com)"
printf 'cache\n' > "$(site_cache_dir good.example.com)/one"
clear_site_cache 2
[[ ! -e "$(site_cache_dir good.example.com)/one" ]]

# Tuning must share the deployment lock; a report cannot overwrite its pending plan.
grep -Fq 'pending-tuning-recommendations.tsv' <<< "$(declare -f apply_tuning)"
ensure_root() { :; }
check_platform() { :; }
init_runtime() { printf 'locked' > "$test_root/route"; }
init_paths() { printf 'unlocked' > "$test_root/route"; }
migrate_legacy_configs() { :; }
load_sites_config() { :; }
ensure_environment_config() { :; }
load_tuning_config() { :; }
load_opcache_config() { :; }
execute_command() { :; }
main tune --apply --yes
[[ "$(<"$test_root/route")" == locked ]]
main analyze 7d
[[ "$(<"$test_root/route")" == unlocked ]]

printf 'Backup fault injection, global tuning budget/locking, atomic metrics and cache-scope tests passed.\n'
