#!/usr/bin/env bash
# Run only in a disposable root container with MariaDB, rsync and Python.
# shellcheck disable=SC1091,SC2016,SC2034,SC2317,SC2329
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || exit 1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/wp-shell-restore-test.XXXXXX)"
TEST_DOMAIN=restore.example.com
TEST_WP_PATH="/var/www/$TEST_DOMAIN/public"
TEST_DB_NAME=wp_restore_fixture
TEST_DB_USER=wp_restore_user
TEST_DB_PASSWORD='restore-test-password'
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
export WP_SHELL_TEST_ROOT_WRITES=yes
source "$repo_root/wp-shell.sh"

db_pid=""
cleanup_restore_test() {
    local pid_file=/run/mysqld/wp-shell-restore.pid
    mariadb --protocol=socket -e "DROP DATABASE IF EXISTS \`$TEST_DB_NAME\`; DROP USER IF EXISTS '$TEST_DB_USER'@'localhost';" >/dev/null 2>&1 || true
    if [[ -n "$db_pid" ]]; then
        kill "$db_pid" 2>/dev/null || true
        wait "$db_pid" 2>/dev/null || true
    elif [[ -f "$pid_file" ]]; then
        kill "$(<"$pid_file")" 2>/dev/null || true
    fi
    rm -rf -- "$test_root" "/var/www/$TEST_DOMAIN"
    rm -f -- "/etc/nginx/sites-available/$TEST_DOMAIN" /tmp/wp-shell-restore-db.log
}
trap cleanup_restore_test EXIT

install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR" "$STATE_DIR"
install -d -o mysql -g mysql -m 0755 /run/mysqld
mariadbd --user=mysql --skip-networking --pid-file=/run/mysqld/wp-shell-restore.pid --log-error=/tmp/wp-shell-restore-db.log &
db_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    if mariadb --protocol=socket -e 'SELECT 1' >/dev/null 2>&1; then break; fi
    sleep 0.1
done
mariadb --protocol=socket -e 'SELECT 1' >/dev/null
mariadb --protocol=socket <<SQL
CREATE DATABASE \`$TEST_DB_NAME\`;
CREATE USER '$TEST_DB_USER'@'localhost' IDENTIFIED BY '$TEST_DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$TEST_DB_NAME\`.* TO '$TEST_DB_USER'@'localhost';
CREATE TABLE \`$TEST_DB_NAME\`.fixture (value VARCHAR(64) NOT NULL);
INSERT INTO \`$TEST_DB_NAME\`.fixture VALUES ('source-one');
SQL

SITE_COUNT=1
SITE_DOMAINS[1]="$TEST_DOMAIN"
SITE_PRIMARY_DOMAINS[1]="$TEST_DOMAIN"
SITE_PHP_VERSIONS[1]=8.3
SITE_WOOCOMMERCE[1]=no
SITE_REDIS_DATABASES[1]=0
SITE_MODES[1]=managed
SITE_PATHS[1]="$TEST_WP_PATH"
create_site_directories "$TEST_DOMAIN" "$TEST_WP_PATH"
set_site_policy "$TEST_DOMAIN" user www-data
printf "<?php\n// source configuration\ndefine( 'DB_PASSWORD', 'old-backup-password' );\n" > "$TEST_WP_PATH/wp-config.php"
printf 'source-one\n' > "$TEST_WP_PATH/index.txt"
set_site_permissions "$TEST_DOMAIN"
install -d -m 0755 /etc/nginx/sites-available
printf 'if (-f /var/www/%s/.wp-shell-maintenance) { return 503; }\n' \
    "$TEST_DOMAIN" > "/etc/nginx/sites-available/$TEST_DOMAIN"

site_wp_cli() {
    local requested_domain="$1" key value
    shift
    [[ "$requested_domain" == "$TEST_DOMAIN" ]] || return 1
    case "$*" in
        'config get DB_USER') printf '%s\n' "$TEST_DB_USER" ;;
        'config get DB_PASSWORD') php -r 'require $argv[1]; fwrite(STDOUT, DB_PASSWORD);' "$TEST_WP_PATH/wp-config.php" ;;
        'config get DB_HOST') printf 'localhost\n' ;;
        'config get DB_NAME') printf '%s\n' "$TEST_DB_NAME" ;;
        'core version') printf '6.8.2\n' ;;
        'maintenance-mode activate') install -m 0600 /dev/null "$TEST_WP_PATH/.maintenance" ;;
        config\ set\ *)
            key="$3"; value="$4"
            sed -i "/define( '$key',/d" "$TEST_WP_PATH/wp-config.php"
            printf "define( '%s', '%s' );\n" "$key" "$value" >> "$TEST_WP_PATH/wp-config.php"
            ;;
        'core is-installed')
            [[ -f "$TEST_WP_PATH/index.txt" ]]
            mariadb --protocol=socket -NBe "SELECT COUNT(*) FROM \`$TEST_DB_NAME\`.fixture" | grep -Fxq 1
            ;;
        *) printf 'Unexpected WP-CLI fixture call: %s\n' "$*" >&2; return 1 ;;
    esac
}
collect_php_pool_status() { printf '0\t1\t0\t0\t0\t10\t8\t1'; }
restore_verify_maintenance_barrier() { :; }
apply_site_redis_connection() { :; }
clear_site_cache() { :; }

database_value() {
    mariadb --protocol=socket -NBe "SELECT value FROM \`$TEST_DB_NAME\`.fixture"
}
set_database_value() {
    mariadb --protocol=socket -e "DELETE FROM \`$TEST_DB_NAME\`.fixture; INSERT INTO \`$TEST_DB_NAME\`.fixture VALUES ('$1');"
}
create_source_backup() {
    local value="$1" output directory
    printf '%s\n' "$value" > "$TEST_WP_PATH/index.txt"
    set_database_value "$value"
    sleep 1
    output="$(backup_site 1)"
    printf '%s\n' "$output"
    directory="${output##*$'\n'}"
    verify_backup_directory "$directory" "$TEST_DOMAIN"
    printf '%s' "${directory##*/}"
}
set_pre_restore_state() {
    local value="$1"
    printf '%s\n' "$value" > "$TEST_WP_PATH/index.txt"
    set_database_value "$value"
    printf "<?php\n// current-config-secret-%s\ndefine( 'DB_PASSWORD', '%s' );\n" \
        "$value" "$TEST_DB_PASSWORD" > "$TEST_WP_PATH/wp-config.php"
    set_site_permissions "$TEST_DOMAIN"
    sleep 1
}
assert_state() {
    local value="$1" journal state
    [[ "$(<"$TEST_WP_PATH/index.txt")" == "$value" ]]
    [[ "$(database_value)" == "$value" ]]
    grep -Fq "current-config-secret-$value" "$TEST_WP_PATH/wp-config.php"
    grep -Fq "define( 'DB_PASSWORD', '$TEST_DB_PASSWORD' );" "$TEST_WP_PATH/wp-config.php"
    [[ ! -e "/var/www/$TEST_DOMAIN/.wp-shell-maintenance" && ! -e "$TEST_WP_PATH/.maintenance" ]]
    journal="$(restore_current_operation_dir "$TEST_DOMAIN")/journal.v1"
    state="$(restore_journal_last_state "$journal")"
    printf '%s' "$state"
}

# The credential rewrite must preserve arbitrary PHP single-quoted password
# characters without placing the secret in WP-CLI argv. Restore the fixture
# password afterwards so the real MariaDB connection remains valid.
special_password=$'restore-&-quote\'-slash\\value'
restore_set_database_password "$TEST_DOMAIN" "$special_password"
[[ "$(site_wp_cli "$TEST_DOMAIN" config get DB_PASSWORD)" == "$special_password" ]]
restore_set_database_password "$TEST_DOMAIN" "$TEST_DB_PASSWORD"

# Successful restore: files and DB move to the selected backup, including the
# source wp-config.php site constants. Current infrastructure DB credentials
# are reapplied before import. The operation reaches committed only after
# validation and maintenance cleanup; its safety backup remains available.
source_id="$(create_source_backup source-one | tail -n 1)"
set_pre_restore_state pre-one

# A configured rule is not enough: if the local HTTPS probe cannot prove a
# 503 barrier, restore stops before the safety snapshot and data mutation.
restore_verify_maintenance_barrier() { return 1; }
if restore_site 1 "$source_id" --confirm > "$test_root/barrier-failure.log" 2>&1; then
    printf 'Restore continued without a proven live maintenance barrier.\n' >&2
    exit 1
fi
[[ "$(assert_state pre-one)" == aborted ]]
grep -Fq 'local HTTPS probe did not return 503' "$test_root/barrier-failure.log"
restore_verify_maintenance_barrier() { :; }

restore_site 1 "$source_id" --confirm
[[ "$(<"$TEST_WP_PATH/index.txt")" == source-one ]]
[[ "$(database_value)" == source-one ]]
grep -Fq '// source configuration' "$TEST_WP_PATH/wp-config.php"
grep -Fq "define( 'DB_PASSWORD', '$TEST_DB_PASSWORD' );" "$TEST_WP_PATH/wp-config.php"
if grep -Fq old-backup-password "$TEST_WP_PATH/wp-config.php"; then exit 1; fi
journal="$(restore_current_operation_dir "$TEST_DOMAIN")/journal.v1"
[[ "$(restore_journal_last_state "$journal")" == committed ]]
safety_id="$(restore_journal_value "$journal" safety-backup)"
verify_backup_directory "$(site_backup_dir "$TEST_DOMAIN")/$safety_id" "$TEST_DOMAIN"
if grep -Fq "$TEST_DB_PASSWORD" "$journal"; then
    printf 'Restore journal leaked a database password.\n' >&2
    exit 1
fi

# Save the production importer so individual fixtures can fail only the
# requested source import while rollback continues to use the real importer.
eval "$(declare -f restore_import_database | sed '1s/restore_import_database/original_restore_import_database/')"

# A partial database import failure after files were applied must restore the
# exact pre-restore files and database automatically.
target_two="$(create_source_backup target-two | tail -n 1)"
set_pre_restore_state pre-two
fault_archive="$(site_backup_dir "$TEST_DOMAIN")/$target_two/database.sql.gz"
restore_import_database() {
    if [[ "$1" == "$fault_archive" ]]; then
        set_database_value partial-two
        return 1
    fi
    original_restore_import_database "$@"
}
if restore_site 1 "$target_two" --confirm > "$test_root/automatic-rollback.log" 2>&1; then
    printf 'A failed source database import reported success.\n' >&2
    exit 1
fi
[[ "$(assert_state pre-two)" == rolled-back ]]
grep -Fq 'pre-restore files and database were recovered' "$test_root/automatic-rollback.log"

# TERM during the destructive file phase follows the same journal rollback
# path. The rollback-stage call still uses the original sync implementation.
eval "$(declare -f restore_sync_tree | sed '1s/restore_sync_tree/original_restore_sync_tree/')"
target_three="$(create_source_backup target-three | tail -n 1)"
set_pre_restore_state pre-three
restore_import_database() { original_restore_import_database "$@"; }
restore_sync_tree() {
    if [[ "$1" == */source-files ]]; then
        printf 'partial-three\n' > "$TEST_WP_PATH/index.txt"
        kill -TERM "$BASHPID"
        return 143
    fi
    original_restore_sync_tree "$@"
}
if restore_site 1 "$target_three" --confirm > "$test_root/signal-rollback.log" 2>&1; then
    printf 'A TERM-interrupted restore reported success.\n' >&2
    exit 1
fi
[[ "$(assert_state pre-three)" == rolled-back ]]

# If both the requested import and safety rollback fail, the journal must be
# recovery-required and Nginx maintenance must remain. A later explicit
# recovery retries idempotently from the recorded safety backup.
restore_sync_tree() { original_restore_sync_tree "$@"; }
target_four="$(create_source_backup target-four | tail -n 1)"
set_pre_restore_state pre-four
fault_archive="$(site_backup_dir "$TEST_DOMAIN")/$target_four/database.sql.gz"
fail_safety_import=yes
restore_import_database() {
    if [[ "$1" == "$fault_archive" ]]; then
        set_database_value partial-four
        return 1
    fi
    if [[ "$fail_safety_import" == yes ]]; then return 1; fi
    original_restore_import_database "$@"
}
if restore_site 1 "$target_four" --confirm > "$test_root/recovery-required.log" 2>&1; then
    printf 'A restore with failed rollback reported success.\n' >&2
    exit 1
fi
journal="$(restore_current_operation_dir "$TEST_DOMAIN")/journal.v1"
[[ "$(restore_journal_last_state "$journal")" == recovery-required ]]
[[ -f "/var/www/$TEST_DOMAIN/.wp-shell-maintenance" ]]
fail_safety_import=no
restore_recover_site 1 --confirm
[[ "$(assert_state pre-four)" == rolled-back ]]
restore_recover_site 1 --confirm
[[ "$(assert_state pre-four)" == rolled-back ]]

# A crash after validation but before maintenance cleanup must finalize the
# already-accepted data instead of rolling it back. Repeating recovery remains
# a no-op after the committed terminal state is recorded.
commit_dir="$(restore_begin_operation "$TEST_DOMAIN" 20260902-090909 "$TEST_WP_PATH" "$TEST_DB_NAME")"
commit_journal="$commit_dir/journal.v1"
for commit_state in source-ready maintenance safety-ready files-applying files-applied \
    database-applying database-applied validating commit-ready; do
    restore_journal_state "$commit_journal" "$commit_state"
done
install -m 0600 /dev/null "/var/www/$TEST_DOMAIN/.wp-shell-maintenance"
install -m 0600 /dev/null "$TEST_WP_PATH/.maintenance"
restore_recover_site 1 --confirm
[[ "$(restore_journal_last_state "$commit_journal")" == committed ]]
[[ ! -e "/var/www/$TEST_DOMAIN/.wp-shell-maintenance" && ! -e "$TEST_WP_PATH/.maintenance" ]]
restore_recover_site 1 --confirm
[[ "$(restore_journal_last_state "$commit_journal")" == committed ]]

printf 'Restore success, credential preservation, barrier refusal, automatic DB rollback, TERM rollback, rollback recovery and commit finalization tests passed.\n'
