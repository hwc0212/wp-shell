#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/wp-shell-v11.sh"
TEST_ROOT="$(mktemp -d /tmp/wp-shell-v11-fresh-boundary.XXXXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export WP_SHELL_TEST_ROOT_WRITES=yes
export WP_SHELL_CONFIG_DIR="$TEST_ROOT/etc/wp-shell"
export WP_SHELL_STATE_DIR="$TEST_ROOT/var/lib/wp-shell"
export WP_SHELL_TEST_V10_ENTRYPOINT="$TEST_ROOT/usr/local/sbin/wp-shell"
export WP_SHELL_TEST_SYSTEMD_DIR="$TEST_ROOT/etc/systemd/system"
export WP_SHELL_LEGACY_VPS_CONFIG_DIR="$TEST_ROOT/etc/wp-vps-manager"
export WP_SHELL_LEGACY_SINGLE_CONFIG_DIR="$TEST_ROOT/etc/wp-single-deploy"
mkdir -p "$WP_SHELL_CONFIG_DIR" "$WP_SHELL_STATE_DIR" \
    "$(dirname "$WP_SHELL_TEST_V10_ENTRYPOINT")" "$WP_SHELL_TEST_SYSTEMD_DIR" \
    "$WP_SHELL_LEGACY_VPS_CONFIG_DIR" "$WP_SHELL_LEGACY_SINGLE_CONFIG_DIR"

# shellcheck source=../wp-shell-v11.sh
source "$SCRIPT"

cat > "$WP_SHELL_CONFIG_DIR/environment.v1" <<'EOF'
version|1
mode|multi
php|8.3
firewall|no
EOF
cat > "$WP_SHELL_TEST_V10_ENTRYPOINT" <<'EOF'
#!/usr/bin/env bash
readonly WP_SHELL_VERSION="10.0.4"
EOF
chmod 0755 "$WP_SHELL_TEST_V10_ENTRYPOINT"
printf 'historical metrics payload\n' > "$WP_SHELL_STATE_DIR/metrics.sqlite3"
printf '[Unit]\nDescription=v10 metrics timer\n' > "$WP_SHELL_TEST_SYSTEMD_DIR/wp-shell-metrics.timer"
printf 'version|2\nsite|legacy-vps.example.com|8.3|no|no|0||||\n' \
    > "$WP_SHELL_LEGACY_VPS_CONFIG_DIR/sites.v2"
printf 'site|2|legacy-single.example.com|legacy-single.example.com|no|8.3|no||||\n' \
    > "$WP_SHELL_LEGACY_SINGLE_CONFIG_DIR/site.v2"
printf 'admin-owned content\n' > "$TEST_ROOT/admin.cnf"
printf 'old unmerged migration marker\n' > "$WP_SHELL_CONFIG_DIR/v10-metrics-migration.v1"

artifact_hashes() {
    sha256sum \
        "$WP_SHELL_CONFIG_DIR/environment.v1" \
        "$WP_SHELL_TEST_V10_ENTRYPOINT" \
        "$WP_SHELL_STATE_DIR/metrics.sqlite3" \
        "$WP_SHELL_TEST_SYSTEMD_DIR/wp-shell-metrics.timer" \
        "$WP_SHELL_LEGACY_VPS_CONFIG_DIR/sites.v2" \
        "$WP_SHELL_LEGACY_SINGLE_CONFIG_DIR/site.v2" \
        "$WP_SHELL_CONFIG_DIR/v10-metrics-migration.v1" \
        "$TEST_ROOT/admin.cnf"
}

legacy_config_hashes() {
    sha256sum \
        "$WP_SHELL_LEGACY_VPS_CONFIG_DIR/sites.v2" \
        "$WP_SHELL_LEGACY_SINGLE_CONFIG_DIR/site.v2" \
        "$TEST_ROOT/admin.cnf"
}

before="$(artifact_hashes)"
details="$(v10_host_footprint_details)"
grep -Fq 'legacy wp-shell entrypoint plus managed configuration' <<<"$details"
grep -Fq "$WP_SHELL_LEGACY_VPS_CONFIG_DIR" <<<"$details"
grep -Fq "$WP_SHELL_LEGACY_SINGLE_CONFIG_DIR" <<<"$details"
grep -Fq 'legacy wp-shell artifact:' <<<"$details"
grep -Fq 'DETECTED' <<<"$(v10_host_footprint_summary)"
[[ "$before" == "$(artifact_hashes)" ]]

# Read-only inspection remains available and never adopts or changes v10 state.
enforce_v11_fresh_deploy_boundary capacity
enforce_v11_fresh_deploy_boundary audit
enforce_v11_fresh_deploy_boundary status
[[ "$before" == "$(artifact_hashes)" ]]
[[ ! -e "$TUNING_CONFIG_FILE" ]]
[[ ! -d "$TRANSACTION_DIR" ]]

# Every v11 write is refused before runtime paths, transactions, services, or
# configuration can be changed. The refusal explains the supported path.
if blocked_output="$( (enforce_v11_fresh_deploy_boundary install) 2>&1)"; then
    blocked_status=0
else
    blocked_status=$?
fi
[[ "$blocked_status" -ne 0 ]]
grep -Fq 'Refusing to modify a host with a detected v10/legacy wp-shell footprint' <<<"$blocked_output"
grep -Fq 'V11 does not support in-place v10 adoption' <<<"$blocked_output"
grep -Fq 'No legacy file, service, database, tuning state, or timer was changed' <<<"$blocked_output"
grep -Fq 'fresh VPS' <<<"$blocked_output"
[[ "$before" == "$(artifact_hashes)" ]]
[[ ! -e "$TUNING_CONFIG_FILE" ]]
[[ ! -d "$TRANSACTION_DIR" ]]

# The real dispatcher invokes the same boundary before init_runtime(). Stub
# only privilege/platform probes so this assertion is safe on non-root CI.
ensure_root() { :; }
check_platform() { :; }
require_command() { :; }
tree_before="$(find "$TEST_ROOT" -type f -printf '%P\n' | sort)"
if main_output="$( (WP_SHELL_V11_EXPERIMENTAL=yes main install) 2>&1)"; then
    main_status=0
else
    main_status=$?
fi
[[ "$main_status" -ne 0 ]]
grep -Fq 'Refusing to modify a host with a detected v10/legacy wp-shell footprint' <<<"$main_output"
[[ "$tree_before" == "$(find "$TEST_ROOT" -type f -printf '%P\n' | sort)" ]]
[[ ! -d "$TRANSACTION_DIR" ]]

# Recognized legacy configuration directories independently block writes when
# the stable entrypoint and metrics artifacts are absent. The guard must not
# adopt, copy, delete, or rewrite either legacy tree.
rm -f -- "$WP_SHELL_TEST_V10_ENTRYPOINT"
details="$(v10_host_footprint_details)"
grep -Fq 'metrics.sqlite3' <<<"$details"
rm -f -- "$WP_SHELL_STATE_DIR/metrics.sqlite3" \
    "$WP_SHELL_TEST_SYSTEMD_DIR/wp-shell-metrics.timer"
details="$(v10_host_footprint_details)"
grep -Fq "$WP_SHELL_LEGACY_VPS_CONFIG_DIR" <<<"$details"
grep -Fq "$WP_SHELL_LEGACY_SINGLE_CONFIG_DIR" <<<"$details"
legacy_before="$(legacy_config_hashes)"
if legacy_output="$( (enforce_v11_fresh_deploy_boundary install) 2>&1)"; then
    legacy_status=0
else
    legacy_status=$?
fi
[[ "$legacy_status" -ne 0 ]]
grep -Fq 'V11 does not support in-place v10 adoption' <<<"$legacy_output"
[[ "$legacy_before" == "$(legacy_config_hashes)" ]]
[[ ! -d "$WP_SHELL_CONFIG_DIR/migration-backup" ]]
[[ ! -f "$SITES_CONFIG_FILE" ]]
[[ ! -f "$REDIS_SECRET_FILE" ]]
[[ ! -d "$DATABASE_CONFIG_DIR" ]]

# Removing the disposable test footprints restores the fresh-deploy path. The
# product never performs this removal itself.
rm -rf -- "$WP_SHELL_LEGACY_VPS_CONFIG_DIR" "$WP_SHELL_LEGACY_SINGLE_CONFIG_DIR"
[[ "$(v10_host_footprint_summary)" == none ]]
enforce_v11_fresh_deploy_boundary install

# Retired commands fail instead of impersonating a collector or migration.
tree_before="$(find "$TEST_ROOT" -type f -printf '%P\n' | sort)"
if retired_output="$( (execute_command metrics collect) 2>&1)"; then
    retired_status=0
else
    retired_status=$?
fi
[[ "$retired_status" -ne 0 ]]
grep -Fq 'automatic dashboard/metrics/tuning command was removed' <<<"$retired_output"
[[ "$tree_before" == "$(find "$TEST_ROOT" -type f -printf '%P\n' | sort)" ]]

# The runtime contains no in-place metrics migration, producer manipulation,
# compatibility collector, SQLite schema, dashboard, or automatic tuner.
if grep -Eq '^migrate_v10_metrics\(\)|^legacy_metrics_status\(\)|^init_metrics_database\(\)|^collect_metrics\(\)|^install_metrics_timer\(\)|^dashboard\(\)|^metrics_report\(\)|^analyze_metrics\(\)|^apply_tuning\(\)' "$SCRIPT"; then
    printf 'Retired v10 metrics/dashboard/tuner code is still present.\n' >&2
    exit 1
fi
if grep -Eq '^migrate_legacy_configs\(\)|^migrate_legacy_vps_config\(\)|^migrate_legacy_single_config\(\)|^legacy_single_command\(\)|legacy-vps|legacy-single' "$SCRIPT"; then
    printf 'V11 still contains a legacy in-place adoption function or route.\n' >&2
    exit 1
fi
if grep -Eq 'systemctl (stop|disable).*wp-shell-metrics|ExecStart=.*metrics collect|apt_install .*sqlite3|v10-metrics-migration[.]v1' "$SCRIPT"; then
    printf 'In-place metrics migration or producer compatibility code is still present.\n' >&2
    exit 1
fi

printf 'v11 fresh-deploy boundary and metrics retirement tests passed.\n'
