#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $EUID -eq 0 ]] || { printf 'This test must run as root in an isolated container.\n' >&2; exit 1; }
command -v mariadbd >/dev/null || { printf 'mariadbd is required.\n' >&2; exit 1; }

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"; rm -f /etc/mysql/mariadb.conf.d/50-wordpress.cnf /etc/mysql/mariadb.conf.d/60-wp-shell.cnf /etc/mysql/mariadb.conf.d/70-wp-shell-test-admin.cnf' EXIT
export WP_SHELL_CONFIG_DIR="$test_root/wp-shell"
export WP_SHELL_STATE_DIR="$test_root/state"
export WP_SHELL_TEST_ROOT_WRITES=yes
source "$repo_root/wp-shell.sh"
mkdir -p "$CONFIG_DIR/transactions" "$STATE_DIR"

memory_mb() { printf '2048'; }
mariadb_health_check() { return 0; }
mariadb_runtime_snapshot() {
    mariadb_config_effective_snapshot
    cat <<'EOF'
max_used_connections|0
threads_connected|0
threads_running|0
created_tmp_tables|0
created_tmp_disk_tables|0
EOF
}
systemctl() { printf '%s\n' "$*" >> "$test_root/systemctl-calls"; }

baseline="$(mariadb_config_effective_snapshot)"
for variable in innodb_buffer_pool_size max_connections tmp_table_size max_heap_table_size; do
    [[ -n "$(mariadb_snapshot_value "$baseline" "$variable")" ]]
done

legacy_file=/etc/mysql/mariadb.conf.d/50-wordpress.cnf
managed_file=/etc/mysql/mariadb.conf.d/60-wp-shell.cnf
admin_file=/etc/mysql/mariadb.conf.d/70-wp-shell-test-admin.cnf
cat > "$legacy_file" <<'EOF'
[mysqld]
# WordPress legacy integration fixture
tmp_table_size = 128M
max_heap_table_size = 128M
innodb_flush_log_at_trx_commit = 1
EOF
cat > "$managed_file" <<'EOF'
[mysqld]
innodb_buffer_pool_size = 256M
max_connections = 80
table_open_cache = 512
EOF
cat > "$admin_file" <<'EOF'
[client]
password = INTEGRATION_SECRET_MUST_NOT_BE_LOGGED
[mysqld]
table_open_cache = 1234
EOF
chmod 0640 "$legacy_file"
managed_hash="$(sha256sum "$managed_file")"
admin_hash="$(sha256sum "$admin_file")"

unsafe="$(mariadb_config_effective_snapshot)"
[[ "$(mariadb_snapshot_value "$unsafe" innodb_buffer_pool_size)" == 268435456 ]]
[[ "$(mariadb_snapshot_value "$unsafe" max_connections)" == 80 ]]
[[ "$(mariadb_snapshot_value "$unsafe" tmp_table_size)" == 134217728 ]]
[[ "$(mariadb_snapshot_value "$unsafe" max_heap_table_size)" == 134217728 ]]

audit_output="$(mariadb_audit)"
grep -Fq '[legacy-wp-shell]' <<< "$audit_output"
if grep -Fq 'INTEGRATION_SECRET_MUST_NOT_BE_LOGGED' <<< "$audit_output"; then
    printf 'Audit leaked an unrelated MariaDB secret.\n' >&2
    exit 1
fi

TRANSACTION_CONTEXT=yes
mariadb_migrate_legacy --confirm > "$test_root/migration-output"
transaction_commit
effective="$(mariadb_config_effective_snapshot)"
[[ "$(mariadb_snapshot_value "$effective" innodb_buffer_pool_size)" == 268435456 ]]
[[ "$(mariadb_snapshot_value "$effective" max_connections)" == 80 ]]
for variable in tmp_table_size max_heap_table_size; do
    [[ "$(mariadb_snapshot_value "$effective" "$variable")" == "$(mariadb_snapshot_value "$baseline" "$variable")" ]] || {
        printf '%s did not return to the distribution effective value.\n' "$variable" >&2
        exit 1
    }
done
[[ "$(sha256sum "$managed_file")" == "$managed_hash" ]]
[[ "$(sha256sum "$admin_file")" == "$admin_hash" ]]
[[ -f "$admin_file" ]]
[[ "$(stat -c '%a' "$legacy_file")" == 640 ]]
grep -Fq 'innodb_flush_log_at_trx_commit = 1' "$legacy_file"
grep -Fxq 'innodb_buffer_pool_size = 256M' "$managed_file"
grep -Fxq 'max_connections = 80' "$managed_file"
grep -Fxq 'table_open_cache = 512' "$managed_file"
[[ "$(grep -Fxc 'restart mariadb' "$test_root/systemctl-calls")" == 1 ]]

restart_count="$(grep -Fxc 'restart mariadb' "$test_root/systemctl-calls")"
mariadb_migrate_legacy --confirm > "$test_root/repeat-output"
[[ "$(grep -Fxc 'restart mariadb' "$test_root/systemctl-calls")" == "$restart_count" ]]
[[ "$(sha256sum "$admin_file")" == "$admin_hash" ]]

# Unsafe managed tuning is a separate case: remove only the unsafe directive,
# preserve the safe 256M value and unrelated content, then remain idempotent.
cat > "$managed_file" <<'EOF'
[mysqld]
innodb_buffer_pool_size = 256M
max_connections = 300
table_open_cache = 777
EOF
unsafe_managed="$(mariadb_config_effective_snapshot)"
[[ "$(mariadb_snapshot_value "$unsafe_managed" max_connections)" == 300 ]]
mariadb_migrate_legacy --confirm > "$test_root/unsafe-managed-output"
transaction_commit
effective="$(mariadb_config_effective_snapshot)"
[[ "$(mariadb_snapshot_value "$effective" innodb_buffer_pool_size)" == 268435456 ]]
[[ "$(mariadb_snapshot_value "$effective" max_connections)" == "$(mariadb_snapshot_value "$baseline" max_connections)" ]]
grep -Fxq 'innodb_buffer_pool_size = 256M' "$managed_file"
grep -Fxq 'table_open_cache = 777' "$managed_file"
if grep -Eq '^[[:space:]]*max_connections[[:space:]]*=' "$managed_file"; then
    printf 'Unsafe managed max_connections survived integration migration.\n' >&2
    exit 1
fi
restart_count="$(grep -Fxc 'restart mariadb' "$test_root/systemctl-calls")"
[[ "$restart_count" == 2 ]]
mariadb_migrate_legacy --confirm > "$test_root/unsafe-managed-repeat-output"
[[ "$(grep -Fxc 'restart mariadb' "$test_root/systemctl-calls")" == "$restart_count" ]]
[[ "$(sha256sum "$admin_file")" == "$admin_hash" ]]

. /etc/os-release
printf 'MariaDB legacy migration integration passed on Ubuntu %s.\n' "$VERSION_ID"
