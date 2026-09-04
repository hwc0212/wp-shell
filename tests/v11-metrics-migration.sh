#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2154,SC2317,SC2329

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/wp-shell-v11.sh"
TEST_ROOT="$(mktemp -d /tmp/wp-shell-v11-migration.XXXXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export WP_SHELL_TEST_ROOT_WRITES=yes
export WP_SHELL_CONFIG_DIR="$TEST_ROOT/etc/wp-shell"
export WP_SHELL_STATE_DIR="$TEST_ROOT/var/lib/wp-shell"
export WP_SHELL_PROC_ROOT="$TEST_ROOT/proc"
mkdir -p "$WP_SHELL_CONFIG_DIR/transactions" "$WP_SHELL_STATE_DIR" "$WP_SHELL_PROC_ROOT" \
    "$TEST_ROOT/pools" "$TEST_ROOT/systemd" "$TEST_ROOT/unit-state"
cat > "$WP_SHELL_PROC_ROOT/meminfo" <<'EOF'
MemTotal:       4194304 kB
MemAvailable:   3145728 kB
SwapTotal:      2097152 kB
SwapFree:       2097152 kB
EOF

# shellcheck source=../wp-shell-v11.sh
source "$SCRIPT"

SITE_COUNT=1
ENVIRONMENT_MODE=multi
DEFAULT_PHP_VERSION=8.3
SITE_DOMAINS[1]=one.example.com
SITE_PRIMARY_DOMAINS[1]=one.example.com
SITE_PHP_VERSIONS[1]=8.3
SITE_WOOCOMMERCE[1]=no
SITE_MODES[1]=managed

site_php_pool_file() { printf '%s/pools/%s.conf' "$TEST_ROOT" "$1"; }
unique_php_versions() { printf '8.3\n'; }
opcache_effective_values() { printf '128 16\n'; }
read_effective_default_pool_limit() { printf '1'; }
read_effective_site_pool_limit() { read_pool_limit "$1" "$2" 0; }
read_effective_pool_settings() {
    if [[ "$2" == www ]]; then printf 'ondemand|1';
    elif [[ "$2" == "$(site_pool_id one.example.com)" ]]; then printf 'ondemand|%s' "$(read_pool_limit one.example.com "$1" 0)";
    else return 1; fi
}

cat > "$(site_php_pool_file one.example.com 8.3)" <<EOF
; Managed by wp-shell for one.example.com.
[$(site_pool_id one.example.com)]
pm = ondemand
pm.max_children = 3
EOF
chmod 0644 "$(site_php_pool_file one.example.com 8.3)"

printf 'TOPSECRET historical payload\n' > "$LEGACY_METRICS_DB"
printf 'wal data\n' > "$LEGACY_METRICS_DB-wal"
printf 'cursor\n' > "$WP_SHELL_STATE_DIR/nginx-one.offset"
printf 'recommendation\n' > "$WP_SHELL_STATE_DIR/last-recommendations.tsv"
printf '[Unit]\nDescription=historical timer\n' > "$TEST_ROOT/systemd/wp-shell-metrics.timer"
printf 'admin_setting=keep\n' > "$TEST_ROOT/admin-mariadb.cnf"
printf 'enabled\n' > "$TEST_ROOT/unit-state/wp-shell-metrics.timer.enabled"
printf 'active\n' > "$TEST_ROOT/unit-state/wp-shell-metrics.timer.active"
printf 'static\n' > "$TEST_ROOT/unit-state/wp-shell-metrics.service.enabled"
printf 'active\n' > "$TEST_ROOT/unit-state/wp-shell-metrics.service.active"

systemctl() {
    local action="$1" unit quiet=no
    shift
    if [[ "${1:-}" == --quiet ]]; then quiet=yes; shift; fi
    case "$action" in
        show)
            unit="${*: -1}"
            [[ -f "$TEST_ROOT/unit-state/$unit.active" ]] && printf 'loaded\n' || printf 'not-found\n'
            ;;
        is-enabled)
            unit="$1"
            [[ -f "$TEST_ROOT/unit-state/$unit.enabled" ]] || return 1
            state="$(<"$TEST_ROOT/unit-state/$unit.enabled")"
            [[ "$quiet" == yes ]] || printf '%s\n' "$state"
            [[ "$state" == enabled ]]
            ;;
        is-active)
            unit="$1"
            [[ -f "$TEST_ROOT/unit-state/$unit.active" ]] || return 1
            state="$(<"$TEST_ROOT/unit-state/$unit.active")"
            [[ "$quiet" == yes ]] || printf '%s\n' "$state"
            [[ "$state" == active ]]
            ;;
        stop)
            for unit in "$@"; do printf 'inactive\n' > "$TEST_ROOT/unit-state/$unit.active"; done
            ;;
        disable)
            unit="$1"
            [[ ! -e "$TEST_ROOT/fail-disable" ]] || return 1
            printf 'disabled\n' > "$TEST_ROOT/unit-state/$unit.enabled"
            ;;
        enable)
            unit="$1"; printf 'enabled\n' > "$TEST_ROOT/unit-state/$unit.enabled"
            ;;
        start)
            unit="$1"; printf 'active\n' > "$TEST_ROOT/unit-state/$unit.active"
            ;;
        *) return 0 ;;
    esac
}
systemd_unit_exists() {
    [[ -f "$TEST_ROOT/unit-state/$1.active" ]]
}

artifact_hashes() {
    sha256sum "$LEGACY_METRICS_DB" "$LEGACY_METRICS_DB-wal" \
        "$WP_SHELL_STATE_DIR/nginx-one.offset" "$WP_SHELL_STATE_DIR/last-recommendations.tsv" \
        "$TEST_ROOT/systemd/wp-shell-metrics.timer" "$TEST_ROOT/admin-mariadb.cnf"
}

# Preview and compatibility collect are read-only/non-writing.
before="$(artifact_hashes)"
preview="$(v10_metrics_migration_report)"
after="$(artifact_hashes)"
[[ "$before" == "$after" ]]
grep -Fq 'Status: LEGACY_METRICS_PRESENT' <<< "$preview"
if grep -Fq TOPSECRET <<< "$preview"; then
    printf 'Migration preview leaked historical content.\n' >&2
    exit 1
fi
before_tree="$(find "$TEST_ROOT" -type f -printf '%P\n' | sort)"
collect_output="$(retired_metrics_command collect)"
after_tree="$(find "$TEST_ROOT" -type f -printf '%P\n' | sort)"
[[ "$before_tree" == "$after_tree" ]]
grep -Fq 'no database, cursor, log, or sample was written' <<< "$collect_output"

# Confirmed migration preserves every historical/admin artifact, adopts the safe current pool,
# and disables only the producer.
TRANSACTION_CONTEXT=yes
migrate_v10_metrics --confirm >/dev/null
transaction_commit >/dev/null
[[ "$before" == "$(artifact_hashes)" ]]
grep -Fxq 'php|one.example.com|3' "$TUNING_CONFIG_FILE"
grep -Fxq 'legacy-data|preserved' "$V10_METRICS_MIGRATION_FILE"
[[ "$(<"$TEST_ROOT/unit-state/wp-shell-metrics.timer.enabled")" == disabled ]]
[[ "$(<"$TEST_ROOT/unit-state/wp-shell-metrics.timer.active")" == inactive ]]
[[ "$(<"$TEST_ROOT/unit-state/wp-shell-metrics.service.active")" == inactive ]]
[[ "$(legacy_metrics_status)" == MIGRATED_INACTIVE_DATA_PRESERVED ]]

# Repeated migration is a no-op: no new transaction and no file changes.
transaction_count="$(find "$TRANSACTION_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)"
state_before="$(sha256sum "$TUNING_CONFIG_FILE" "$V10_METRICS_MIGRATION_FILE")"
migrate_v10_metrics --confirm >/dev/null
[[ "$transaction_count" == "$(find "$TRANSACTION_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" ]]
[[ "$state_before" == "$(sha256sum "$TUNING_CONFIG_FILE" "$V10_METRICS_MIGRATION_FILE")" ]]

# A producer-disable failure restores the prior exact unit state and rolls back new files.
rm -f "$TUNING_CONFIG_FILE" "$V10_METRICS_MIGRATION_FILE"
printf 'enabled\n' > "$TEST_ROOT/unit-state/wp-shell-metrics.timer.enabled"
printf 'active\n' > "$TEST_ROOT/unit-state/wp-shell-metrics.timer.active"
printf 'active\n' > "$TEST_ROOT/unit-state/wp-shell-metrics.service.active"
touch "$TEST_ROOT/fail-disable"
if failure_output="$(migrate_v10_metrics --confirm 2>&1)"; then failure_status=0; else failure_status=$?; fi
[[ "$failure_status" -ne 0 ]]
grep -Fq 'Failed to disable the legacy metrics producer' <<< "$failure_output"
[[ ! -e "$TUNING_CONFIG_FILE" ]]
[[ ! -e "$V10_METRICS_MIGRATION_FILE" ]]
[[ "$(<"$TEST_ROOT/unit-state/wp-shell-metrics.timer.enabled")" == enabled ]]
[[ "$(<"$TEST_ROOT/unit-state/wp-shell-metrics.timer.active")" == active ]]
[[ "$(<"$TEST_ROOT/unit-state/wp-shell-metrics.service.active")" == active ]]
[[ "$before" == "$(artifact_hashes)" ]]

# The v11 runtime contains no SQLite collector/schema/timer installer.
if grep -Eq '^init_metrics_database\(\)|^collect_metrics\(\)|^install_metrics_timer\(\)|ExecStart=.*metrics collect|apt_install .*sqlite3' "$SCRIPT"; then
    printf 'Legacy metrics runtime or dependency is still installed by v11.\n' >&2
    exit 1
fi

printf 'v11 metrics retirement and migration tests passed.\n'
