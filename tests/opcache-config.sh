#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2016,SC2034,SC2079,SC2317,SC2329
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
source "$repo_root/wp-shell.sh"
install -d -m 0700 "$CONFIG_DIR"
opcache_scan_dir() { printf '%s/php/%s' "$test_root" "$1"; }
for test_version in 8.2 8.3 8.4; do mkdir -p "$(opcache_scan_dir "$test_version")"; done

expect_failure() {
    if ( "$@" ) > "$test_root/failure-output" 2>&1; then
        printf 'Expected failure: %s\n' "$*" >&2
        exit 1
    fi
}

load_opcache_config
[[ "$(opcache_values 8.4)" == '128 16' ]]
validate_opcache_values 256 32
for invalid in '0256' '0' '63' '4096' '256;false' '1+255' '99999999999999999999999'; do
    expect_failure validate_opcache_values "$invalid" 32
done
expect_failure validate_opcache_values 256 129
expect_failure validate_opcache_values 256 032

local_ini="$(opcache_scan_dir 8.4)/99-zz-local-opcache.ini"
printf '; Existing hand-written settings\nopcache.memory_consumption = 256 ; retained\nopcache.interned_strings_buffer = "32"\n' > "$local_ini"
local_hash="$(sha256sum "$local_ini")"
[[ "$(opcache_values 8.4)" == '256 32' ]]
OPCACHE_MEMORY_OVERRIDES[8.4]=384
OPCACHE_STRINGS_OVERRIDES[8.4]=48
save_opcache_config
[[ "$(stat -c '%a' "$OPCACHE_CONFIG_FILE")" == 600 ]]
load_opcache_config
[[ "$(opcache_values 8.4)" == '384 48' ]]
[[ "$(sha256sum "$local_ini")" == "$local_hash" ]]
cp "$OPCACHE_CONFIG_FILE" "$test_root/good-config"
for record in 'version|2' 'version|1\nphp|8.4|256|32\nphp|8.4|384|48' 'version|1\nphp|8.5|256|32' 'version|1\nphp|8.4|256|32|extra' 'version|1\nphp|8.4|$(touch /not-allowed)|32'; do
    printf '%b\n' "$record" > "$OPCACHE_CONFIG_FILE"
    expect_failure load_opcache_config
done
cp "$test_root/good-config" "$OPCACHE_CONFIG_FILE"
load_opcache_config

memory_mb() { printf '3832'; }
available_memory_mb() { printf '2080'; }
DEFAULT_PHP_VERSION=8.4
ENVIRONMENT_MODE=multi
SITE_COUNT=2
SITE_DOMAINS[1]=first.example.com
SITE_DOMAINS[2]=second.example.com
SITE_WOOCOMMERCE[1]=yes
SITE_WOOCOMMERCE[2]=no
SITE_PHP_VERSIONS[1]=8.4
SITE_PHP_VERSIONS[2]=8.4
OPCACHE_MEMORY_OVERRIDES[8.4]=256
OPCACHE_STRINGS_OVERRIDES[8.4]=32
calculate_resource_budget quiet
[[ "$OPCACHE_TOTAL_BUDGET_MB" == 256 && "$PHP_TOTAL_BUDGET_MB" == 1246 ]]
[[ "${SITE_PHP_MAX_CHILDREN[1]} ${SITE_PHP_MAX_CHILDREN[2]}" == '8 4' ]]
SITE_PHP_VERSIONS[2]=8.3
calculate_resource_budget quiet
[[ "$OPCACHE_TOTAL_BUDGET_MB" == 384 ]]
SITE_PHP_VERSIONS[2]=8.4
calculate_resource_budget quiet
OPCACHE_MEMORY_OVERRIDES[8.2]=128
OPCACHE_STRINGS_OVERRIDES[8.2]=16
calculate_resource_budget quiet
[[ "$OPCACHE_TOTAL_BUDGET_MB" == 384 ]]
unset 'OPCACHE_MEMORY_OVERRIDES[8.2]' 'OPCACHE_STRINGS_OVERRIDES[8.2]'
calculate_resource_budget quiet

# Simulate the service boundary while exercising real file transactions.
service_calls="$test_root/systemctl-calls"
systemctl() {
    printf '%s\n' "$*" >> "$service_calls"
    if [[ "$*" == reload* && -f "$test_root/reject-reload-once" ]]; then
        rm -f "$test_root/reject-reload-once"
        return 1
    fi
    [[ ! -f "$test_root/reject-daemon-reload" || "$1" != daemon-reload ]]
}
php-fpm8.4() { [[ ! -f "$test_root/reject-fpm-test" ]]; }
opcache_effective_values() {
    if [[ -f "$test_root/later-ini-conflict" ]]; then printf '128 16'; return; fi
    local ini
    ini="$(opcache_managed_ini "$1")"
    if [[ -f "$ini" ]]; then
        awk -F ' = ' '/^opcache.memory_consumption/ {m=$2} /^opcache.interned_strings_buffer/ {s=$2} END {print m " " s}' "$ini"
    else
        printf '128 16'
    fi
}
opcache_runtime_json() { return 1; }
save_opcache_config
set_opcache 8.4 256 32 > "$test_root/set-output"
[[ "$(opcache_effective_values 8.4)" == '256 32' ]]
[[ "$(sha256sum "$local_ini")" == "$local_hash" ]]
[[ "$(stat -c '%a' "$(opcache_managed_ini 8.4)")" == 644 ]]
[[ "$(tail -n 2 "$service_calls")" == $'daemon-reload\nreload php8.4-fpm' ]]
grep -q 'No Nginx, database, Redis, or pool limits changed' "$test_root/set-output"
load_opcache_config
[[ "${OPCACHE_MEMORY_OVERRIDES[8.4]} ${OPCACHE_STRINGS_OVERRIDES[8.4]}" == '256 32' ]]

original_ini_hash="$(sha256sum "$(opcache_managed_ini 8.4)")"
original_state_hash="$(sha256sum "$OPCACHE_CONFIG_FILE")"
for failure in reject-fpm-test later-ini-conflict reject-reload-once reject-daemon-reload; do
    : > "$test_root/$failure"
    expect_failure set_opcache 8.4 384 48
    [[ "$(sha256sum "$(opcache_managed_ini 8.4)")" == "$original_ini_hash" ]]
    [[ "$(sha256sum "$OPCACHE_CONFIG_FILE")" == "$original_state_hash" ]]
    grep -q 'previous files restored' "$test_root/failure-output"
    rm -f "$test_root/$failure"
done
# Failure before the first successful application must restore absence, not leave a new override.
(
    rm -f "$OPCACHE_CONFIG_FILE" "$(opcache_managed_ini 8.4)"
    : > "$test_root/reject-fpm-test"
    expect_failure set_opcache 8.4 256 32
    [[ ! -e "$OPCACHE_CONFIG_FILE" && ! -e "$(opcache_managed_ini 8.4)" ]]
    rm -f "$test_root/reject-fpm-test"
)
save_opcache_config
write_opcache_ini 8.4 256 32
expect_failure set_opcache 8.4 1024 32
available_memory_mb() { printf '10'; }
expect_failure set_opcache 8.4 384 32
[[ "$(sha256sum "$(opcache_managed_ini 8.4)")" == "$original_ini_hash" ]]
available_memory_mb() { printf '2080'; }

printf '; Not owned by wp-shell\n' > "$(opcache_managed_ini 8.3)"
expect_failure write_opcache_ini 8.3 128 16
grep -qx '; Not owned by wp-shell' "$(opcache_managed_ini 8.3)"
ln -s "$local_ini" "$(opcache_managed_ini 8.2)"
expect_failure write_opcache_ini 8.2 128 16
[[ "$(sha256sum "$local_ini")" == "$local_hash" ]]

output="$(execute_command opcache status 8.4)"
grep -q 'Runtime: unavailable' <<< "$output"
grep -q 'Configuration on disk (memory/strings MB): 256 32' <<< "$output"
expect_failure execute_command opcache set 8.4 256
expect_failure execute_command opcache status 8.4 extra
opcache_runtime_json() {
    printf '%s\n' '{"available":true,"memory_mb":128,"strings_mb":16,"enabled":true,"full":true,"used_mb":128,"free_mb":0,"wasted_mb":0,"strings_used_mb":16,"strings_free_mb":0,"scripts":100,"keys":101,"max_keys":20000,"hit_rate":53,"oom_restarts":2,"hash_restarts":0,"manual_restarts":1,"restart_pending":false,"restart_in_progress":false,"start_time":1780000000}'
}
output="$(execute_command opcache status 8.4)"
grep -q 'Running FPM settings differ' <<< "$output"
grep -q 'full or nearly full' <<< "$output"
opcache_menu() { printf 'OPCACHE_MENU_CALLED\n'; }
install_self() { return 0; }
output="$(management_menu <<< '16')"
grep -q 'OPCACHE_MENU_CALLED' <<< "$output"
grep -q '16) OPcache settings' <<< "$output"

printf 'OPcache validation, persistence, budgets, rollback, and routing tests passed.\n'
