#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2154,SC2004,SC2317,SC2329

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/wp-shell-v11-capacity.XXXXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export WP_SHELL_TEST_ROOT_WRITES=yes
export WP_SHELL_CONFIG_DIR="$TEST_ROOT/etc/wp-shell"
export WP_SHELL_STATE_DIR="$TEST_ROOT/var/lib/wp-shell"
export WP_SHELL_PROC_ROOT="$TEST_ROOT/proc"
mkdir -p "$WP_SHELL_CONFIG_DIR" "$WP_SHELL_STATE_DIR" "$WP_SHELL_PROC_ROOT"

# shellcheck source=../wp-shell-v11.sh
source "$ROOT_DIR/wp-shell-v11.sh"

write_meminfo() {
    local ram_mb="$1" swap_total_mb="$2" swap_free_mb="$3"
    cat > "$WP_SHELL_PROC_ROOT/meminfo" <<EOF
MemTotal:       $((ram_mb * 1024)) kB
MemAvailable:   $((ram_mb * 700)) kB
SwapTotal:      $((swap_total_mb * 1024)) kB
SwapFree:       $((swap_free_mb * 1024)) kB
EOF
}

set_sites() {
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
    PHP_CHILD_OVERRIDES=()
}

declare -A TEST_EFFECTIVE=(
    [one.example.com]=2
    [two.example.com]=3
)

TEST_PHP_VERSIONS=$'8.3\n'
TEST_CPU_COUNT=2
unique_php_versions() { printf '%s' "$TEST_PHP_VERSIONS"; }
cpu_count() { printf '%s' "$TEST_CPU_COUNT"; }
opcache_effective_values() { printf '128 16\n'; }
read_effective_default_pool_limit() { printf '1'; }
read_effective_site_pool_limit() {
    [[ -n "${TEST_EFFECTIVE[$1]+present}" ]] || return 1
    printf '%s' "${TEST_EFFECTIVE[$1]}"
}
read_managed_site_pool_limit() { read_effective_site_pool_limit "$1"; }
redis_effective_maxmemory_summary() { printf '96MB'; }

set_sites
write_meminfo 2048 0 0

php_worker_memory_estimate
[[ "$PHP_WORKER_ESTIMATE_MB" == 96 ]]
grep -Fq 'conservative baseline' <<< "$PHP_WORKER_EVIDENCE"

pool="$(site_pool_id one.example.com)"
mkdir -p "$WP_SHELL_PROC_ROOT/101"
printf 'php-fpm: pool %s\0' "$pool" > "$WP_SHELL_PROC_ROOT/101/cmdline"
printf 'Pss:              122880 kB\n' > "$WP_SHELL_PROC_ROOT/101/smaps_rollup"
ln -s /usr/sbin/php-fpm8.3 "$WP_SHELL_PROC_ROOT/101/exe"
php_worker_memory_estimate
[[ "$PHP_WORKER_ESTIMATE_MB" == 150 ]]
grep -Fq 'current managed FPM worker max PSS 120MB plus 25% safety margin' <<< "$PHP_WORKER_EVIDENCE"

printf 'Pss:               51200 kB\n' > "$WP_SHELL_PROC_ROOT/101/smaps_rollup"
php_worker_memory_estimate
[[ "$PHP_WORKER_ESTIMATE_MB" == 96 ]]
grep -Fq 'floor 96MB/process' <<< "$PHP_WORKER_EVIDENCE"
rm -rf -- "$WP_SHELL_PROC_ROOT/101"

# Large but untrusted/stale-like entries do not influence the estimate: wrong
# pool title, wrong executable, and invalid smaps content are all discarded.
for pid in 201 202 203; do mkdir -p "$WP_SHELL_PROC_ROOT/$pid"; done
printf 'php-fpm: pool wp_not_managed\0' > "$WP_SHELL_PROC_ROOT/201/cmdline"
printf 'Pss:              999999 kB\n' > "$WP_SHELL_PROC_ROOT/201/smaps_rollup"
ln -s /usr/sbin/php-fpm8.3 "$WP_SHELL_PROC_ROOT/201/exe"
printf 'php-fpm: pool %s\0' "$pool" > "$WP_SHELL_PROC_ROOT/202/cmdline"
printf 'Pss:              999999 kB\n' > "$WP_SHELL_PROC_ROOT/202/smaps_rollup"
ln -s /usr/bin/php "$WP_SHELL_PROC_ROOT/202/exe"
printf 'php-fpm: pool %s\0' "$pool" > "$WP_SHELL_PROC_ROOT/203/cmdline"
printf 'Pss:              invalid kB\n' > "$WP_SHELL_PROC_ROOT/203/smaps_rollup"
ln -s /usr/sbin/php-fpm8.3 "$WP_SHELL_PROC_ROOT/203/exe"
php_worker_memory_estimate
[[ "$PHP_WORKER_ESTIMATE_MB" == 96 ]]
grep -Fq 'no valid current managed FPM worker PSS' <<< "$PHP_WORKER_EVIDENCE"
rm -rf -- "$WP_SHELL_PROC_ROOT/201" "$WP_SHELL_PROC_ROOT/202" "$WP_SHELL_PROC_ROOT/203"

# Swap is observable but never increases the resident PHP worker budget.
write_meminfo 2048 0 0
calculate_resource_budget_values quiet effective
budget_without_swap="$PHP_TOTAL_BUDGET_MB"
write_meminfo 2048 2048 1024
calculate_resource_budget_values quiet effective
[[ "$PHP_TOTAL_BUDGET_MB" == "$budget_without_swap" ]]

# Initial sizing is useful but conservative: two workers for a normal site and
# up to three for explicit WooCommerce, bounded here to four automatic site
# workers by two CPUs. It does not consume every memory-safe slot.
calculate_site_php_allocations
[[ "${SITE_PHP_MAX_CHILDREN[1]}" == 2 ]]
[[ "${SITE_PHP_MAX_CHILDREN[2]}" == 2 ]]
[[ "$PHP_INITIAL_AUTO_WORKER_CEILING" == 4 ]]
[[ "$PHP_REQUESTED_AGGREGATE_WORKERS" == 5 ]]
((PHP_REQUESTED_AGGREGATE_WORKERS < PHP_SAFE_AGGREGATE_WORKERS))
PHP_CHILD_OVERRIDES["one.example.com"]=3
calculate_site_php_allocations
[[ "${SITE_PHP_MAX_CHILDREN[1]}" == 3 ]]
[[ "${SITE_PHP_MAX_CHILDREN[2]}" == 2 ]]
[[ "$PHP_REQUESTED_AGGREGATE_WORKERS" == 6 ]]

# Capacity is strictly current-state and read-only.
PHP_CHILD_OVERRIDES=()
before="$(find "$TEST_ROOT" -type f -not -path '*/proc/*' -print0 | sort -z | xargs -0 -r sha256sum)"
capacity_output="$(php_capacity_status_report)"
after="$(find "$TEST_ROOT" -type f -not -path '*/proc/*' -print0 | sort -z | xargs -0 -r sha256sum)"
[[ "$before" == "$after" ]]
grep -Fq 'PHP capacity: SAFE' <<< "$capacity_output"
grep -Fq 'Aggregate effective workers: 6' <<< "$capacity_output"
grep -Fq 'Swap: total=2048MB used=1024MB' <<< "$capacity_output"
grep -Fq 'Effective OPcache: PHP 8.3 memory=128MB strings=16MB' <<< "$capacity_output"

# Matrix: practical initial defaults are deterministic across 1/2/4/8/16GB,
# site types and site counts. Every success satisfies both the CPU policy and
# hard aggregate memory invariant. A 1GB host is conservatively refused when
# even the default pool plus one site cannot fit; Swap does not change that.
model_sites() {
    local count="$1" mix="$2" imported_last="${3:-no}" i domain
    SITE_COUNT="$count"
    SITE_DOMAINS=(); SITE_PRIMARY_DOMAINS=(); SITE_PHP_VERSIONS=()
    SITE_WOOCOMMERCE=(); SITE_MODES=(); PHP_CHILD_OVERRIDES=()
    for ((i=1; i<=count; i++)); do
        domain="site${i}.example.com"
        SITE_DOMAINS[$i]="$domain"; SITE_PRIMARY_DOMAINS[$i]="$domain"
        SITE_PHP_VERSIONS[$i]=8.3; SITE_MODES[$i]=managed
        case "$mix" in
            normal) SITE_WOOCOMMERCE[$i]=no ;;
            woo) SITE_WOOCOMMERCE[$i]=yes ;;
            mixed) if ((i % 2)); then SITE_WOOCOMMERCE[$i]=no; else SITE_WOOCOMMERCE[$i]=yes; fi ;;
        esac
    done
    [[ "$imported_last" != yes ]] || SITE_MODES[$count]=imported
}

assert_initial_profile() {
    local ram="$1" cpus="$2" count="$3" mix="$4" expected="$5" actual i
    model_sites "$count" "$mix"
    TEST_PHP_VERSIONS=$'8.3\n'
    TEST_CPU_COUNT="$cpus"
    write_meminfo "$ram" 0 0
    calculate_resource_budget quiet
    actual=""
    for ((i=1; i<=SITE_COUNT; i++)); do
        actual+="${actual:+,}${SITE_PHP_MAX_CHILDREN[$i]}"
    done
    [[ "$actual" == "$expected" ]]
    ((PHP_ESTIMATED_ALLOCATION_MB <= PHP_TOTAL_BUDGET_MB))
    ((PHP_REQUESTED_AGGREGATE_WORKERS <= PHP_SAFE_AGGREGATE_WORKERS))
    ((PHP_INITIAL_AUTO_WORKER_CEILING <= cpus * PHP_INITIAL_WORKERS_PER_CPU || SITE_COUNT > cpus * PHP_INITIAL_WORKERS_PER_CPU))
}

for one_gb_mix in normal woo; do
    model_sites 1 "$one_gb_mix"
    TEST_CPU_COUNT=1
    write_meminfo 1024 0 0
    if calculate_resource_budget quiet advisory; then one_gb_status=0; else one_gb_status=$?; fi
    [[ "$one_gb_status" -ne 0 ]]
    grep -Fq 'cannot fit the PHP worker budget' <<< "$PHP_CAPACITY_ERROR"
done

assert_initial_profile 2048 2 1 normal 2
assert_initial_profile 2048 2 1 woo 3
assert_initial_profile 2048 2 2 normal 2,2
assert_initial_profile 2048 2 2 woo 2,2
assert_initial_profile 2048 2 2 mixed 2,2
assert_initial_profile 4096 2 2 mixed 2,2
assert_initial_profile 8192 4 3 mixed 2,3,2
assert_initial_profile 16384 8 6 mixed 2,3,2,3,2,3
((PHP_REQUESTED_AGGREGATE_WORKERS < PHP_SAFE_AGGREGATE_WORKERS))

# Multiple PHP versions reserve an effective default pool and OPcache per version.
model_sites 2 mixed
SITE_PHP_VERSIONS[2]=8.4
TEST_PHP_VERSIONS=$'8.3\n8.4\n'
TEST_CPU_COUNT=2
write_meminfo 4096 256 256
calculate_resource_budget quiet
[[ "$PHP_DEFAULT_POOL_WORKERS" == 2 ]]
[[ "$OPCACHE_TOTAL_BUDGET_MB" == 256 ]]
((PHP_ESTIMATED_ALLOCATION_MB <= PHP_TOTAL_BUDGET_MB))

# Imported sites participate in prospective apply admission, and aggregate manual
# overrides cannot pass merely because each per-site value is within 1..50.
model_sites 3 mixed yes
TEST_PHP_VERSIONS=$'8.3\n'
TEST_CPU_COUNT=2
write_meminfo 2048 2048 2048
calculate_resource_budget quiet
[[ "$PHP_REQUESTED_AGGREGATE_WORKERS" == 5 ]]
PHP_CHILD_OVERRIDES["site1.example.com"]=50
PHP_CHILD_OVERRIDES["site2.example.com"]=50
if calculate_resource_budget quiet advisory; then override_status=0; else override_status=$?; fi
[[ "$override_status" -ne 0 ]]
grep -Fq 'Requested aggregate workers: 102' <<< "$PHP_CAPACITY_ERROR"

# An imported site's wp-shell-managed PHP pool remains part of current
# aggregate exposure. If that effective pool cannot be read, capacity must be
# UNKNOWN instead of silently omitting it.
PHP_CHILD_OVERRIDES=()
TEST_EFFECTIVE[site1.example.com]=2
TEST_EFFECTIVE[site2.example.com]=3
TEST_EFFECTIVE[site3.example.com]=4
capacity_output="$(php_capacity_status_report)"
grep -Fq 'Aggregate effective workers: 10' <<< "$capacity_output"
grep -Fq 'site3.example.com' <<< "$capacity_output"
unset 'TEST_EFFECTIVE[site3.example.com]'
capacity_output="$(php_capacity_status_report)"
grep -Fq 'PHP capacity: UNKNOWN' <<< "$capacity_output"

# A current effective aggregate above the same hard budget is never called safe.
set_sites
TEST_PHP_VERSIONS=$'8.3\n'
write_meminfo 2048 2048 1024
TEST_EFFECTIVE[one.example.com]=4
TEST_EFFECTIVE[two.example.com]=4
capacity_output="$(php_capacity_status_report)"
grep -Fq 'PHP capacity: OVERCOMMITTED' <<< "$capacity_output"

# Unknown effective OPcache or pool data is fail-closed.
opcache_effective_values() { return 1; }
capacity_output="$(php_capacity_status_report)"
grep -Fq 'PHP capacity: UNKNOWN' <<< "$capacity_output"
grep -Fq 'Hard PHP worker budget: UNKNOWN' <<< "$capacity_output"

printf 'v11 capacity and current-PSS tests passed.\n'
