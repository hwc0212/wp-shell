#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export WP_SHELL_CONFIG_DIR="$test_root/wp-shell"
export WP_SHELL_STATE_DIR="$test_root/state"
export WP_SHELL_MARIADB_CONFIG_ROOT="$test_root/mysql"
export WP_SHELL_TEST_ROOT_WRITES=yes
source "$repo_root/wp-shell.sh"

mkdir -p "$CONFIG_DIR/transactions" "$STATE_DIR" \
    "$MARIADB_CONFIG_ROOT/conf.d" "$MARIADB_CONFIG_ROOT/mariadb.conf.d"
cat > "$MARIADB_CONFIG_ROOT/my.cnf" <<'EOF'
[client-server]
sort_buffer_size = 1M
EOF
cat > "$MARIADB_CONFIG_ROOT/conf.d/40-administrator.cnf" <<'EOF'
[mysqld]
sort_buffer_size = 2M
EOF
cat > "$MARIADB_CONFIG_ROOT/mariadb.conf.d/50-wordpress.cnf" <<'EOF'
[mysqld]
# WordPress legacy fixture
max_connections = 300
innodb_buffer_pool_size = 1G
tmp_table_size = 128M
max_heap_table_size = 128M
innodb_flush_log_at_trx_commit = 1
EOF
cat > "$MARIADB_MANAGED_CONFIG_FILE" <<'EOF'
[mysqld]
bind-address = 127.0.0.1
max_connections = 300
EOF
cat > "$MARIADB_CONFIG_ROOT/mariadb.conf.d/70-administrator.cnf" <<'EOF'
[client]
password = SHOULD_NOT_APPEAR_IN_AUDIT_OUTPUT
[mysqld]
table_open_cache = 777
join_buffer_size = SHOULD_NOT_APPEAR_IN_AUDIT_OUTPUT
EOF
chmod 0640 "$MARIADB_CONFIG_ROOT/mariadb.conf.d/50-wordpress.cnf"

legacy_file="$MARIADB_CONFIG_ROOT/mariadb.conf.d/50-wordpress.cnf"
admin_file="$MARIADB_CONFIG_ROOT/mariadb.conf.d/70-administrator.cnf"
legacy_original="$test_root/legacy-original.cnf"
managed_original="$test_root/managed-original.cnf"
cp -a "$legacy_file" "$legacy_original"
cp -a "$MARIADB_MANAGED_CONFIG_FILE" "$managed_original"
admin_hash="$(sha256sum "$admin_file")"

memory_mb() { printf '2048'; }
mariadb_validate_fragment() { return 0; }
mariadb_validate_installed_config() { return 0; }
mariadb_health_check() { return 0; }
mariadb_config_effective_snapshot() {
    if grep -Eq '^[[:space:]]*max_connections[[:space:]]*=[[:space:]]*300' "$legacy_file"; then
        cat <<'EOF'
innodb_buffer_pool_size|1073741824
max_connections|300
tmp_table_size|134217728
max_heap_table_size|134217728
sort_buffer_size|2097152
join_buffer_size|262144
read_buffer_size|131072
read_rnd_buffer_size|262144
thread_stack|299008
EOF
    else
        cat <<'EOF'
innodb_buffer_pool_size|134217728
max_connections|151
tmp_table_size|16777216
max_heap_table_size|16777216
sort_buffer_size|2097152
join_buffer_size|262144
read_buffer_size|131072
read_rnd_buffer_size|262144
thread_stack|299008
EOF
    fi
}
mariadb_runtime_snapshot() {
    mariadb_config_effective_snapshot
    cat <<'EOF'
max_used_connections|12
threads_connected|3
threads_running|1
created_tmp_tables|100
created_tmp_disk_tables|7
EOF
}
systemctl() {
    printf '%s\n' "$*" >> "$test_root/systemctl-calls"
    if [[ "$*" == 'restart mariadb' && -e "$test_root/fail-next-restart" ]]; then
        rm -f "$test_root/fail-next-restart"
        return 1
    fi
    return 0
}

# A normal audit is fully read-only, reports actual/runtime values separately,
# identifies the historical file and never emits unrelated secrets.
before_tree="$(find "$MARIADB_CONFIG_ROOT" -type f -print0 | sort -z | xargs -0 sha256sum)"
audit_output="$(mariadb_audit)"
after_tree="$(find "$MARIADB_CONFIG_ROOT" -type f -print0 | sort -z | xargs -0 sha256sum)"
[[ "$before_tree" == "$after_tree" ]]
grep -Fq 'innodb_buffer_pool_size' <<< "$audit_output"
grep -Fq '1073741824 bytes (1024 MiB)' <<< "$audit_output"
grep -Fq 'max_used_connections' <<< "$audit_output"
grep -Fq "$legacy_file" <<< "$audit_output"
grep -Fq '[legacy-wp-shell]' <<< "$audit_output"
grep -Fq 'sort_buffer_size                1M' <<< "$audit_output"
grep -Fq 'sort_buffer_size                2M' <<< "$audit_output"
grep -Fq "$MARIADB_CONFIG_ROOT/conf.d/40-administrator.cnf:2" <<< "$audit_output"
grep -Fq 'Explicit migration: wp-shell mariadb migrate-legacy --confirm' <<< "$audit_output"
if grep -Fq 'SHOULD_NOT_APPEAR_IN_AUDIT_OUTPUT' <<< "$audit_output"; then
    printf 'MariaDB audit leaked an unrelated administrator secret.\n' >&2
    exit 1
fi

# A routine apply must stop before rendering, writing or restarting while the
# dangerous legacy state remains present.
if (configure_mariadb) > "$test_root/apply-output" 2>&1; then
    printf 'Routine MariaDB apply accepted an unsafe legacy configuration.\n' >&2
    exit 1
fi
grep -Fq 'mariadb migrate-legacy --confirm' "$test_root/apply-output"
[[ ! -e "$test_root/systemctl-calls" ]]
[[ "$(sha256sum "$legacy_file" | cut -d' ' -f1)" == "$(sha256sum "$legacy_original" | cut -d' ' -f1)" ]]

# The explicit transaction strips only the four recognized memory directives,
# restarts once because effective values changed, and preserves administrator
# content byte-for-byte.
TRANSACTION_CONTEXT=yes
mariadb_migrate_legacy --confirm > "$test_root/migration-output"
transaction_commit
for option in innodb_buffer_pool_size max_connections tmp_table_size max_heap_table_size; do
    if grep -Eq "^[[:space:]]*${option}[[:space:]]*=" "$legacy_file"; then
        printf 'Legacy option survived migration: %s\n' "$option" >&2
        exit 1
    fi
done
if grep -Eq '^[[:space:]]*max_connections[[:space:]]*=' "$MARIADB_MANAGED_CONFIG_FILE"; then
    printf 'Managed legacy max_connections survived migration.\n' >&2
    exit 1
fi
grep -Fq 'innodb_flush_log_at_trx_commit = 1' "$legacy_file"
[[ "$(stat -c '%a' "$legacy_file")" == 640 ]]
[[ "$(sha256sum "$admin_file")" == "$admin_hash" ]]
grep -Fxq 'restart mariadb' "$test_root/systemctl-calls"
[[ "$(mariadb_snapshot_value "$(mariadb_config_effective_snapshot)" max_connections)" == 151 ]]

# Repeating the migration is a no-op and causes no second restart.
restart_count="$(grep -Fxc 'restart mariadb' "$test_root/systemctl-calls")"
mariadb_migrate_legacy --confirm > "$test_root/migration-repeat-output"
[[ "$(grep -Fxc 'restart mariadb' "$test_root/systemctl-calls")" == "$restart_count" ]]
[[ "$(sha256sum "$admin_file")" == "$admin_hash" ]]

# Fault injection: the first restart fails. Automatic rollback must restore the
# exact original file, including mode and comments; the recovery restart then
# receives the previous configuration.
cp -a "$legacy_original" "$legacy_file"
cp -a "$managed_original" "$MARIADB_MANAGED_CONFIG_FILE"
legacy_fingerprint="$(stat -c '%a:%U:%G' "$legacy_file"):$(sha256sum "$legacy_file" | cut -d' ' -f1)"
managed_fingerprint="$(stat -c '%a:%U:%G' "$MARIADB_MANAGED_CONFIG_FILE"):$(sha256sum "$MARIADB_MANAGED_CONFIG_FILE" | cut -d' ' -f1)"
touch "$test_root/fail-next-restart"
if (TRANSACTION_ACTIVE=no; TRANSACTION_CONTEXT=yes; mariadb_migrate_legacy --confirm) > "$test_root/restart-failure-output" 2>&1; then
    printf 'The injected MariaDB restart failure unexpectedly succeeded.\n' >&2
    exit 1
fi
[[ "$(stat -c '%a:%U:%G' "$legacy_file"):$(sha256sum "$legacy_file" | cut -d' ' -f1)" == "$legacy_fingerprint" ]]
[[ "$(stat -c '%a:%U:%G' "$MARIADB_MANAGED_CONFIG_FILE"):$(sha256sum "$MARIADB_MANAGED_CONFIG_FILE" | cut -d' ' -f1)" == "$managed_fingerprint" ]]
[[ "$(sha256sum "$admin_file")" == "$admin_hash" ]]
[[ -f "$admin_file" ]]

printf 'MariaDB legacy audit, admission, explicit migration, idempotence, secret filtering and exact rollback tests passed.\n'
