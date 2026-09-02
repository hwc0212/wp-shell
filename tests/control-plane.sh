#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
source "$repo_root/wp-shell.sh"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$CONFIG_DIR/transactions"

owner="$(id -un)"
group="$(id -gn)"
target="$CONFIG_DIR/fixture.conf"
printf 'old\n' > "$target"
chmod 0600 "$target"

TRANSACTION_CONTEXT=yes
CURRENT_STEP="control plane fixture"
write_managed_file "$target" 0600 "$owner" "$group" <<'EOF'
new
EOF
[[ "$(<"$target")" == new && "$TRANSACTION_ACTIVE" == yes ]]
transaction_commit
first_id="$(<"$LAST_TRANSACTION_FILE")"
first_path="$TRANSACTION_DIR/$first_id"
grep -q '^committed|' "$first_path/manifest.v1"
grep -q '^after|' "$first_path/manifest.v1"
transaction_rollback_internal "$first_path" manual
[[ "$(<"$target")" == old ]]

# Re-applying identical content is a no-op and creates no transaction.
TRANSACTION_ACTIVE=no
TRANSACTION_ID=""
write_managed_file "$target" 0600 "$owner" "$group" <<'EOF'
old
EOF
[[ "$TRANSACTION_ACTIVE" == no ]]

# A dry run must report a plan without changing the file.
DRY_RUN=yes
plan="$(write_managed_file "$target" 0600 "$owner" "$group" <<'EOF'
dry-run-value
EOF
)"
grep -Fq "PLAN write $target" <<< "$plan"
[[ "$(<"$target")" == old ]]
DRY_RUN=no

# Manual rollback refuses to overwrite a later operator change.
write_managed_file "$target" 0600 "$owner" "$group" <<'EOF'
managed-second
EOF
transaction_commit
second_id="$(<"$LAST_TRANSACTION_FILE")"
printf 'operator-change\n' > "$target"
if transaction_rollback_internal "$TRANSACTION_DIR/$second_id" manual >/dev/null 2>&1; then
    printf 'Rollback overwrote a post-commit operator change.\n' >&2
    exit 1
fi
[[ "$(<"$target")" == operator-change ]]

# An error in an active transaction restores the pre-change file without
# waiting for an operator to invoke rollback.
auto_target="$CONFIG_DIR/auto-rollback.conf"
printf 'before-error\n' > "$auto_target"
chmod 0600 "$auto_target"
if bash -c '
    set -Eeuo pipefail
    export WP_SHELL_CONFIG_DIR="$5"
    export WP_SHELL_STATE_DIR="$6"
    source "$1"
    TRANSACTION_ACTIVE=no
    TRANSACTION_ID=""
    TRANSACTION_CONTEXT=yes
    write_managed_file "$2" 0600 "$3" "$4" <<<after-error
    false
' _ "$repo_root/wp-shell.sh" "$auto_target" "$owner" "$group" "$CONFIG_DIR" "$STATE_DIR"; then
    printf 'The deliberate transaction failure unexpectedly succeeded.\n' >&2
    exit 1
fi
[[ "$(<"$auto_target")" == before-error ]]

# Explicit validation failures use die(), which must have the same rollback
# semantics even though Bash does not run an ERR trap for a direct exit.
printf 'before-validation\n' > "$auto_target"
if bash -c '
    set -Eeuo pipefail
    export WP_SHELL_CONFIG_DIR="$5"
    export WP_SHELL_STATE_DIR="$6"
    source "$1"
    TRANSACTION_CONTEXT=yes
    write_managed_file "$2" 0600 "$3" "$4" <<<after-validation
    die "deliberate candidate validation failure"
' _ "$repo_root/wp-shell.sh" "$auto_target" "$owner" "$group" "$CONFIG_DIR" "$STATE_DIR"; then
    printf 'The deliberate validation failure unexpectedly succeeded.\n' >&2
    exit 1
fi
[[ "$(<"$auto_target")" == before-validation ]]

# The public audit/status/dry-run entry points must not create paths, migrate
# legacy data, or synthesize configuration before executing their read-only
# implementation.
readonly_sentinel="$test_root/read-only-mutated"
for readonly_command in audit status dry-run; do
    bash -c '
        set -Eeuo pipefail
        source "$1"
        ensure_root() { :; }
        check_platform() { :; }
        require_command() { :; }
        init_paths() { touch "$2"; }
        migrate_legacy_configs() { touch "$2"; }
        ensure_environment_config() { touch "$2"; }
        load_sites_config() { :; }
        load_environment_config() { :; }
        load_tuning_config() { :; }
        load_opcache_config() { :; }
        execute_command() { :; }
        main "$3"
    ' _ "$repo_root/wp-shell.sh" "$readonly_sentinel" "$readonly_command"
    [[ ! -e "$readonly_sentinel" ]]
done

# The dedicated MariaDB audit has the same read-only routing guarantee, while
# migrate-legacy intentionally uses the locked transaction path.
bash -c '
    set -Eeuo pipefail
    source "$1"
    ensure_root() { :; }
    check_platform() { :; }
    require_command() { :; }
    init_paths() { touch "$2"; }
    init_runtime() { touch "$2"; }
    migrate_legacy_configs() { touch "$2"; }
    ensure_environment_config() { touch "$2"; }
    load_sites_config() { :; }
    load_environment_config() { :; }
    load_tuning_config() { :; }
    load_opcache_config() { :; }
    execute_command() { :; }
    main mariadb audit
' _ "$repo_root/wp-shell.sh" "$readonly_sentinel"
[[ ! -e "$readonly_sentinel" ]]

# Queue inspection must use the observational WP-CLI wrapper.  A regression
# back to site_wp_cli would create/cache files during `wp-shell audit`.
readonly_wpcli_calls="$test_root/read-only-wpcli-calls"
site_wp_cli() {
    printf 'mutating-wrapper-used\n' >> "$readonly_wpcli_calls"
    return 1
}
site_wp_cli_readonly() {
    printf '%s\n' "$*" >> "$readonly_wpcli_calls"
    case "$*" in
        *'cron event list'*) printf '3\n' ;;
        *'db prefix'*) printf 'wp_\n' ;;
        *"SHOW TABLES LIKE 'wp_actionscheduler_actions'"*) printf 'wp_actionscheduler_actions\n' ;;
        *"status='pending'"*) printf '7\n' ;;
        *"status='failed'"*) printf '1\n' ;;
    esac
}
queue_output="$(wordpress_queue_status example.com)"
grep -Fq 'wp-cron-due=3 action-scheduler-pending=7 failed=1' <<< "$queue_output"
if grep -Fq 'mutating-wrapper-used' "$readonly_wpcli_calls"; then
    printf 'Queue audit used the mutating WP-CLI wrapper.\n' >&2
    exit 1
fi

printf 'Transactional write, idempotence, dry-run, rollback and conflict tests passed.\n'
