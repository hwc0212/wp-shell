#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2154,SC2317,SC2329

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/wp-shell-v11-workers.XXXXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export WP_SHELL_TEST_ROOT_WRITES=yes
export WP_SHELL_CONFIG_DIR="$TEST_ROOT/etc/wp-shell"
export WP_SHELL_STATE_DIR="$TEST_ROOT/var/lib/wp-shell"
export WP_SHELL_PROC_ROOT="$TEST_ROOT/proc"
mkdir -p "$WP_SHELL_CONFIG_DIR/transactions" "$WP_SHELL_STATE_DIR" "$WP_SHELL_PROC_ROOT" "$TEST_ROOT/pools" "$TEST_ROOT/bin"
cat > "$WP_SHELL_PROC_ROOT/meminfo" <<'EOF'
MemTotal:       2097152 kB
MemAvailable:   1572864 kB
SwapTotal:      2097152 kB
SwapFree:       2097152 kB
EOF
cat > "$TEST_ROOT/bin/php-fpm8.3" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$TEST_ROOT/bin/php-fpm8.3"
export PATH="$TEST_ROOT/bin:$PATH"

# shellcheck source=../wp-shell-v11.sh
source "$ROOT_DIR/wp-shell-v11.sh"

SITE_COUNT=2
ENVIRONMENT_MODE=multi
DEFAULT_PHP_VERSION=8.3
SITE_DOMAINS[1]=one.example.com
SITE_DOMAINS[2]=two.example.com
SITE_PRIMARY_DOMAINS[1]=one.example.com
SITE_PRIMARY_DOMAINS[2]=two.example.com
SITE_PHP_VERSIONS[1]=8.3
SITE_PHP_VERSIONS[2]=8.3
SITE_WOOCOMMERCE[1]=no
SITE_WOOCOMMERCE[2]=yes
SITE_MODES[1]=managed
SITE_MODES[2]=managed

site_php_pool_file() { printf '%s/pools/%s.conf' "$TEST_ROOT" "$1"; }
unique_php_versions() { printf '8.3\n'; }
opcache_effective_values() { printf '128 16\n'; }
read_effective_default_pool_limit() { printf '1'; }
legacy_metrics_status() { printf ABSENT; }
ADMIN_OVERRIDE=""
POST_WRITE_OVERRIDE=no
read_effective_site_pool_limit() {
    local value
    value="$(read_pool_limit "$1" "$2" 0)"
    if [[ "$1" == one.example.com && -n "$ADMIN_OVERRIDE" ]]; then
        printf '%s' "$ADMIN_OVERRIDE"
    elif [[ "$1" == one.example.com && "$POST_WRITE_OVERRIDE" == yes && "$value" == 1 ]]; then
        printf '6'
    else
        printf '%s' "$value"
    fi
}
read_effective_pool_settings() {
    local pool="$2" domain
    [[ "$pool" != www ]] || { printf 'ondemand|1'; return 0; }
    for domain in one.example.com two.example.com; do
        if [[ "$pool" == "$(site_pool_id "$domain")" ]]; then
            printf 'ondemand|%s' "$(read_effective_site_pool_limit "$domain" "$1")"
            return 0
        fi
    done
    return 1
}
RELOADS=0
RELOAD_FAIL=no
php_fpm_service_action() {
    [[ "$1" == reload && "$2" == 8.3 ]]
    RELOADS=$((RELOADS + 1))
    [[ "$RELOAD_FAIL" != yes ]]
}

for domain in one.example.com two.example.com; do
    cat > "$(site_php_pool_file "$domain" 8.3)" <<EOF
; Managed by wp-shell for $domain.
[$(site_pool_id "$domain")]
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 20s
EOF
    chmod 0644 "$(site_php_pool_file "$domain" 8.3)"
done

# Imported-site lifecycle remains unchanged, but once its PHP pool is managed
# by wp-shell it participates in capacity accounting and may be adjusted only
# after the same ownership/admission checks.
SITE_MODES[2]=imported
imported_preview="$(site_workers_command two.example.com 2)"
grep -Fq 'Site: two.example.com' <<< "$imported_preview"
grep -Fq 'Admission: SAFE' <<< "$imported_preview"

# Preview is read-only, includes the prospective aggregate, and requires explicit confirmation.
pool_before="$(sha256sum "$(site_php_pool_file one.example.com 8.3)")"
preview="$(site_workers_command one.example.com 3)"
[[ "$pool_before" == "$(sha256sum "$(site_php_pool_file one.example.com 8.3)")" ]]
[[ ! -e "$TUNING_CONFIG_FILE" ]]
[[ -z "$(find "$TRANSACTION_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]
[[ "$RELOADS" == 0 ]]
grep -Fq 'Prospective aggregate workers: 6' <<< "$preview"
grep -Fq 'Admission: SAFE' <<< "$preview"

# Confirmed change updates only the target pool and manual desired state, validates, and reloads once.
TRANSACTION_CONTEXT=yes
site_workers_command one.example.com 3 --confirm >/dev/null
transaction_commit >/dev/null
[[ "$(read_pool_limit one.example.com 8.3 0)" == 3 ]]
[[ "$(read_pool_limit two.example.com 8.3 0)" == 2 ]]
grep -Fxq 'php|one.example.com|3' "$TUNING_CONFIG_FILE"
[[ "$RELOADS" == 1 ]]
transaction_count="$(find "$TRANSACTION_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)"

# Exact repeat is a no-op: no transaction and no reload.
site_workers_command one.example.com 3 --confirm >/dev/null
[[ "$RELOADS" == 1 ]]
[[ "$(find "$TRANSACTION_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$transaction_count" ]]

# Global aggregate validation rejects an individually valid but collectively unsafe limit.
if blocked="$(site_workers_command one.example.com 4 2>&1)"; then blocked_status=0; else blocked_status=$?; fi
[[ "$blocked_status" -ne 0 ]]
grep -Fq 'Admission: BLOCKED' <<< "$blocked"
[[ "$(read_pool_limit one.example.com 8.3 0)" == 3 ]]
[[ "$RELOADS" == 1 ]]

# A later administrator override blocks ownership before any write.
ADMIN_OVERRIDE=4
if override_output="$(site_workers_command one.example.com 2 --confirm 2>&1)"; then override_status=0; else override_status=$?; fi
[[ "$override_status" -ne 0 ]]
grep -Fq 'administrator override owns the effective value' <<< "$override_output"
[[ "$(read_pool_limit one.example.com 8.3 0)" == 3 ]]
ADMIN_OVERRIDE=""

# If effective -tt semantics differ after the candidate write, exact pool/tuning state is rolled back.
pool_before="$(sha256sum "$(site_php_pool_file one.example.com 8.3)")"
tuning_before="$(sha256sum "$TUNING_CONFIG_FILE")"
POST_WRITE_OVERRIDE=yes
if rollback_output="$(site_workers_command one.example.com 1 --confirm 2>&1)"; then rollback_status=0; else rollback_status=$?; fi
[[ "$rollback_status" -ne 0 ]]
grep -Fq 'rolling back without reload' <<< "$rollback_output"
[[ "$pool_before" == "$(sha256sum "$(site_php_pool_file one.example.com 8.3)")" ]]
[[ "$tuning_before" == "$(sha256sum "$TUNING_CONFIG_FILE")" ]]
[[ "$RELOADS" == 1 ]]
POST_WRITE_OVERRIDE=no

# Reload failure also restores the exact previous files and never reports success.
pool_before="$(sha256sum "$(site_php_pool_file one.example.com 8.3)")"
tuning_before="$(sha256sum "$TUNING_CONFIG_FILE")"
RELOAD_FAIL=yes
if reload_output="$(site_workers_command one.example.com 2 --confirm 2>&1)"; then reload_status=0; else reload_status=$?; fi
[[ "$reload_status" -ne 0 ]]
if grep -Fq '[SUCCESS] Set one.example.com' <<< "$reload_output"; then
    printf 'Reload failure must not report success.\n' >&2
    exit 1
fi
[[ "$pool_before" == "$(sha256sum "$(site_php_pool_file one.example.com 8.3)")" ]]
[[ "$tuning_before" == "$(sha256sum "$TUNING_CONFIG_FILE")" ]]

printf 'v11 manual worker transaction tests passed.\n'
