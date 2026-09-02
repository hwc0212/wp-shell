#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034,SC2317,SC2329
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
source "$repo_root/wp-shell.sh"
install -d -m 0700 "$CONFIG_DIR" "$STATE_DIR"

TEST_RAM_MB=2048
TEST_SWAP_MB=0
TEST_SWAP_USED_MB=0
memory_mb() { printf '%s' "$TEST_RAM_MB"; }
swap_memory_mb() { printf '%s' "$TEST_SWAP_MB"; }
swap_used_mb() { printf '%s' "$TEST_SWAP_USED_MB"; }
TEST_EFFECTIVE_DEFAULT_LIMIT=1
TEST_EFFECTIVE_DEFAULT_KNOWN=yes
declare -A TEST_EFFECTIVE_SITE_LIMITS=()
declare -A TEST_MANAGED_SITE_LIMITS=()
read_effective_default_pool_limit() {
    [[ "$TEST_EFFECTIVE_DEFAULT_KNOWN" == yes ]] || return 1
    printf '%s' "$TEST_EFFECTIVE_DEFAULT_LIMIT"
}
read_effective_site_pool_limit() {
    printf '%s' "${TEST_EFFECTIVE_SITE_LIMITS[$1]:-1}"
}
read_managed_site_pool_limit() {
    printf '%s' "${TEST_MANAGED_SITE_LIMITS[$1]:-${TEST_EFFECTIVE_SITE_LIMITS[$1]:-1}}"
}

reset_profile() {
    local ram="$1" count="$2" layout="${3:-normal}" version_layout="${4:-one}" i
    TEST_RAM_MB="$ram"
    TEST_SWAP_MB=0
    TEST_SWAP_USED_MB=0
    TEST_EFFECTIVE_DEFAULT_LIMIT=1
    TEST_EFFECTIVE_DEFAULT_KNOWN=yes
    TEST_EFFECTIVE_SITE_LIMITS=()
    TEST_MANAGED_SITE_LIMITS=()
    ENVIRONMENT_MODE=multi
    DEFAULT_PHP_VERSION=8.3
    SITE_COUNT="$count"
    SITE_DOMAINS=()
    SITE_PRIMARY_DOMAINS=()
    SITE_PHP_VERSIONS=()
    SITE_WOOCOMMERCE=()
    SITE_WWW=()
    SITE_REDIS_DATABASES=()
    SITE_MODES=()
    SITE_PHP_MAX_CHILDREN=()
    PHP_CHILD_OVERRIDES=()
    OPCACHE_MEMORY_OVERRIDES=()
    OPCACHE_STRINGS_OVERRIDES=()
    rm -f "$METRICS_DB"
    for ((i=1; i<=count; i++)); do
        SITE_DOMAINS[i]="site${i}.example.com"
        SITE_PRIMARY_DOMAINS[i]="site${i}.example.com"
        SITE_PHP_VERSIONS[i]=8.3
        [[ "$version_layout" != multi ]] || SITE_PHP_VERSIONS[i]="8.$((2 + (i-1)%3))"
        SITE_WOOCOMMERCE[i]=no
        case "$layout" in
            woo) SITE_WOOCOMMERCE[i]=yes ;;
            mixed) ((i % 2 == 1)) && SITE_WOOCOMMERCE[i]=yes ;;
        esac
        SITE_MODES[i]=managed
    done
}

assert_success_invariant() {
    local workers i
    calculate_resource_budget quiet
    workers="$PHP_DEFAULT_POOL_WORKERS"
    for ((i=1; i<=SITE_COUNT; i++)); do workers=$((workers + SITE_PHP_MAX_CHILDREN[i])); done
    [[ "$workers" == "$PHP_REQUESTED_AGGREGATE_WORKERS" ]]
    ((workers * PHP_WORKER_ESTIMATE_MB <= PHP_TOTAL_BUDGET_MB))
    ((PHP_ESTIMATED_ALLOCATION_MB <= PHP_TOTAL_BUDGET_MB))
}

assert_admission_failure() {
    if calculate_resource_budget quiet advisory; then
        printf 'Expected PHP capacity admission to fail: RAM=%s sites=%s\n' "$TEST_RAM_MB" "$SITE_COUNT" >&2
        exit 1
    fi
    [[ -n "$PHP_CAPACITY_ERROR" ]]
}

# VPS profile matrix: 1GB is explicitly rejected when even one site plus the
# default pool cannot fit. Larger hosts cover normal, WooCommerce and mixed
# layouts; every successful result must satisfy the hard aggregate invariant.
for ram in 1024 2048 4096 8192 16384; do
    reset_profile "$ram" 1 normal
    ENVIRONMENT_MODE=single
    if ((ram == 1024)); then assert_admission_failure; else assert_success_invariant; fi
    reset_profile "$ram" 1 woo
    ENVIRONMENT_MODE=single
    if ((ram == 1024)); then assert_admission_failure; else assert_success_invariant; fi
    reset_profile "$ram" 2 normal
    if ((ram == 1024)); then assert_admission_failure; else assert_success_invariant; fi
    reset_profile "$ram" 2 woo
    if ((ram == 1024)); then assert_admission_failure; else assert_success_invariant; fi
    reset_profile "$ram" 3 mixed
    if ((ram == 1024)); then assert_admission_failure; else assert_success_invariant; fi
done

# WooCommerce weighting changes distribution, never aggregate capacity.
reset_profile 4096 3 normal
assert_success_invariant
normal_total="$PHP_REQUESTED_AGGREGATE_WORKERS"
normal_allocation="${SITE_PHP_MAX_CHILDREN[*]}"
reset_profile 4096 3 mixed
assert_success_invariant
[[ "$PHP_REQUESTED_AGGREGATE_WORKERS" == "$normal_total" ]]
((SITE_PHP_MAX_CHILDREN[1] > SITE_PHP_MAX_CHILDREN[2]))
[[ "${SITE_PHP_MAX_CHILDREN[*]}" != "$normal_allocation" ]]

# One default pool per active PHP version is charged to the same hard budget.
reset_profile 2048 2 mixed multi
assert_success_invariant
[[ "$PHP_DEFAULT_POOL_WORKERS" == 2 ]]
reset_profile 2048 3 mixed multi
assert_admission_failure
grep -Fq 'default PHP pool reserve(s)' <<< "$PHP_CAPACITY_ERROR"

# An upgraded v10.0.3 host can still expose two workers in its current [www]
# pool even though the new plan targets one. Current-state reporting and the
# tuning veto must use effective evidence rather than the planned target.
reset_profile 2048 1 normal
assert_success_invariant
[[ "$PHP_DEFAULT_POOL_WORKERS" == 1 ]]
TEST_EFFECTIVE_DEFAULT_LIMIT=2
TEST_EFFECTIVE_SITE_LIMITS[site1.example.com]=6
php_refresh_current_aggregate_workers
[[ "$PHP_CURRENT_AGGREGATE_WORKERS" == 8 ]]
grep -Fq 'above the' <<< "$(php_tuning_host_veto_reasons 3600)"

# Unknown effective default-pool capacity is never presented as safe and
# fails closed for automatic tuning expansion.
TEST_EFFECTIVE_DEFAULT_KNOWN=no
capacity_output="$(php_capacity_status_report)"
grep -Fq 'PHP capacity: UNKNOWN' <<< "$capacity_output"
grep -Fq 'Current managed/default workers: UNKNOWN' <<< "$capacity_output"
grep -Fq 'automatic expansion is vetoed' <<< "$(php_tuning_host_veto_reasons 3600)"

# Swap never changes worker budget or allocation for identical physical RAM.
reset_profile 2048 1 normal
assert_success_invariant
without_swap_budget="$PHP_TOTAL_BUDGET_MB"
without_swap_children="${SITE_PHP_MAX_CHILDREN[1]}"
without_swap_workers="$PHP_REQUESTED_AGGREGATE_WORKERS"
TEST_SWAP_MB=2048
TEST_SWAP_USED_MB=256
assert_success_invariant
[[ "$PHP_TOTAL_BUDGET_MB" == "$without_swap_budget" ]]
[[ "${SITE_PHP_MAX_CHILDREN[1]}" == "$without_swap_children" ]]
[[ "$PHP_REQUESTED_AGGREGATE_WORKERS" == "$without_swap_workers" ]]
TEST_SWAP_MB=256
TEST_SWAP_USED_MB=0
assert_success_invariant
[[ "$PHP_TOTAL_BUDGET_MB" == "$without_swap_budget" ]]
[[ "${SITE_PHP_MAX_CHILDREN[1]}" == "$without_swap_children" ]]

# Imported/legacy counts and aggregate manual overrides cannot bypass admission.
reset_profile 2048 20 mixed
assert_admission_failure
reset_profile 4096 2 mixed
PHP_CHILD_OVERRIDES[site1.example.com]=3
PHP_CHILD_OVERRIDES[site2.example.com]=4
assert_success_invariant
[[ "${SITE_PHP_MAX_CHILDREN[1]} ${SITE_PHP_MAX_CHILDREN[2]}" == '3 4' ]]
reset_profile 2048 2 mixed
PHP_CHILD_OVERRIDES[site1.example.com]=50
PHP_CHILD_OVERRIDES[site2.example.com]=50
assert_admission_failure
grep -Fq 'Physical RAM: 2048MB' <<< "$PHP_CAPACITY_ERROR"
grep -Fq 'Swap: total 0MB, used 0MB' <<< "$PHP_CAPACITY_ERROR"
grep -Fq 'site1.example.com=50' <<< "$PHP_CAPACITY_ERROR"
grep -Fq 'Sites involved: site1.example.com[WooCommerce], site2.example.com' <<< "$PHP_CAPACITY_ERROR"
grep -Fq 'reduce site count' <<< "$PHP_CAPACITY_ERROR"

# tune --apply changes only site pools, so prospective admission must retain
# the current effective default pool instead of assuming configure_php's
# future default target of one worker.
reset_profile 4096 2 normal
PHP_TOTAL_BUDGET_MB=768
PHP_WORKER_ESTIMATE_MB=96
TEST_EFFECTIVE_DEFAULT_LIMIT=2
TEST_EFFECTIVE_SITE_LIMITS[site1.example.com]=3
TEST_EFFECTIVE_SITE_LIMITS[site2.example.com]=3
TEST_MANAGED_SITE_LIMITS[site1.example.com]=3
TEST_MANAGED_SITE_LIMITS[site2.example.com]=3
cat > "$test_root/exact-budget-recommendations.tsv" <<'EOF'
site1.example.com|3|4|fixture
EOF
php_refresh_current_aggregate_workers
[[ "$PHP_CURRENT_AGGREGATE_WORKERS" == 8 ]]
if php_validate_tuning_recommendations "$test_root/exact-budget-recommendations.tsv" > "$test_root/exact-budget-output" 2>&1; then
    printf 'Tuning exceeded the current effective aggregate budget.\n' >&2
    exit 1
fi
grep -Fq '9 workers' "$test_root/exact-budget-output"
grep -Fq 'above the 768MB hard budget' "$test_root/exact-budget-output"
TEST_EFFECTIVE_DEFAULT_LIMIT=1
php_validate_tuning_recommendations "$test_root/exact-budget-recommendations.tsv"

# Matching the managed file is an ownership precondition. A later external
# override that changes the effective site limit blocks automatic tuning.
TEST_EFFECTIVE_SITE_LIMITS[site1.example.com]=5
if php_validate_tuning_recommendations "$test_root/exact-budget-recommendations.tsv" > "$test_root/site-override-output" 2>&1; then
    printf 'An externally overridden site pool was accepted for tuning.\n' >&2
    exit 1
fi
grep -Fq 'managed pool limit is 3 but php-fpm reports effective limit 5' "$test_root/site-override-output"

# Allocation is deterministic and idempotent.
reset_profile 8192 4 mixed
assert_success_invariant
first_allocation="${SITE_PHP_MAX_CHILDREN[*]}|$PHP_TOTAL_BUDGET_MB|$PHP_WORKER_ESTIMATE_MB"
assert_success_invariant
[[ "${SITE_PHP_MAX_CHILDREN[*]}|$PHP_TOTAL_BUDGET_MB|$PHP_WORKER_ESTIMATE_MB" == "$first_allocation" ]]

# Insufficient PSS history keeps the established 96MB baseline. Sufficient,
# fresh history uses a robust p95 and 25% margin; upper-tail outliers do not
# become a low average that could justify extra capacity.
reset_profile 4096 1 normal
init_metrics_database
now="$(date +%s)"
sqlite3 "$METRICS_DB" <<SQL
WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<1000)
INSERT INTO site_samples(ts,domain,php_active,php_idle,php_pss_mb)
SELECT $now-(1000-i)*90,'site1.example.com',1,0,CASE WHEN i<=950 THEN 80 ELSE 160 END FROM n;
INSERT INTO sample_health SELECT ts,domain,'php',1 FROM site_samples;
SQL
assert_success_invariant
[[ "$PHP_WORKER_ESTIMATE_MB" == 100 ]]
grep -Fq 'p95 plus 25% safety margin' <<< "$PHP_WORKER_EVIDENCE"
sqlite3 "$METRICS_DB" 'DELETE FROM site_samples WHERE rowid NOT IN (SELECT rowid FROM site_samples ORDER BY ts DESC LIMIT 10); DELETE FROM sample_health; INSERT INTO sample_health SELECT ts,domain,"php",1 FROM site_samples;'
assert_success_invariant
[[ "$PHP_WORKER_ESTIMATE_MB" == 96 ]]

# Unsafe admission stops apply/configure before MariaDB, pool writes, reloads,
# or tuning policy mutation.
reset_profile 2048 2 mixed
PHP_CHILD_OVERRIDES[site1.example.com]=50
PHP_CHILD_OVERRIDES[site2.example.com]=50
live_changes="$test_root/live-changes"
control_plane_plan() { :; }
configure_mariadb() { printf 'mariadb\n' >> "$live_changes"; }
configure_redis() { printf 'redis\n' >> "$live_changes"; }
install_system_packages() { printf 'packages\n' >> "$live_changes"; }
write_managed_file() { printf 'write\n' >> "$live_changes"; }
systemctl() { printf 'systemctl\n' >> "$live_changes"; }
if (apply_control_plane --confirm) > "$test_root/apply-failure" 2>&1; then
    printf 'Unsafe apply unexpectedly succeeded.\n' >&2
    exit 1
fi
[[ ! -e "$live_changes" ]]
if (prepare_stack) > "$test_root/stack-failure" 2>&1; then
    printf 'Unsafe stack preparation unexpectedly succeeded.\n' >&2
    exit 1
fi
[[ ! -e "$live_changes" ]]
if (configure_php) > "$test_root/php-failure" 2>&1; then
    printf 'Unsafe direct PHP configuration unexpectedly succeeded.\n' >&2
    exit 1
fi
[[ ! -e "$live_changes" ]]

printf 'php|site1.example.com|1\n' > "$TUNING_CONFIG_FILE"
tuning_hash="$(sha256sum "$TUNING_CONFIG_FILE")"
cat > "$test_root/unsafe-recommendations.tsv" <<'EOF'
site1.example.com|1|50|fixture
site2.example.com|1|50|fixture
EOF
if php_validate_tuning_recommendations "$test_root/unsafe-recommendations.tsv" >/dev/null 2>&1; then
    printf 'Aggregate-unsafe tuning recommendations were accepted.\n' >&2
    exit 1
fi
[[ "$(sha256sum "$TUNING_CONFIG_FILE")" == "$tuning_hash" ]]
[[ ! -e "$live_changes" ]]

# Tuning expansion vetoes: OOM delta, sustained Swap, memory PSI, severe IO,
# unsafe MariaDB effective state and an existing aggregate PHP overcommit.
reset_profile 4096 1 normal
init_metrics_database
now="$(date +%s)"
sqlite3 "$METRICS_DB" <<SQL
INSERT INTO system_samples VALUES($now-60,10,1,4096,2500,0,20,0,0);
INSERT INTO system_samples VALUES($now,10,1,4096,2500,0,20,0,0);
INSERT INTO system_pressure VALUES($now-60,0,0,0,0,10,0);
INSERT INTO system_pressure VALUES($now,0,0,0,0,10,1);
SQL
calculate_resource_budget quiet
mariadb_apply_block_reason() { :; }
grep -Fq 'OOM counter increased' <<< "$(php_tuning_host_veto_reasons 3600)"
sqlite3 "$METRICS_DB" 'UPDATE system_pressure SET oom_kills=0; UPDATE system_samples SET swap_used_mb=128;'
grep -Fq 'sustained or growing Swap' <<< "$(php_tuning_host_veto_reasons 3600)"
sqlite3 "$METRICS_DB" 'UPDATE system_samples SET swap_used_mb=0; UPDATE system_pressure SET memory_psi=2;'
grep -Fq 'Memory PSI reached' <<< "$(php_tuning_host_veto_reasons 3600)"
sqlite3 "$METRICS_DB" 'UPDATE system_pressure SET memory_psi=0,io_psi=6;'
grep -Fq 'Severe IO pressure' <<< "$(php_tuning_host_veto_reasons 3600)"
mariadb_apply_block_reason() { printf 'unsafe MariaDB fixture'; }
grep -Fq 'unsafe MariaDB fixture' <<< "$(php_tuning_host_veto_reasons 3600)"
mariadb_apply_block_reason() { :; }
TEST_EFFECTIVE_SITE_LIMITS[site1.example.com]=50
grep -Fq 'above the' <<< "$(php_tuning_host_veto_reasons 3600)"

printf 'PHP hard memory budget matrix, admission, evidence, tuning veto and no-write regression tests passed.\n'
