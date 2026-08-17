#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts=(
    "$repo_root/wp-shell.sh"
    "$repo_root/wp-vps-manager.sh"
    "$repo_root/deploy-single-wordpress.sh"
)

for script in "${scripts[@]}"; do
    bash -n "$script"
    [[ "$(head -n 1 "$script")" == '#!/usr/bin/env bash' ]]
    grep -q '^set -Eeuo pipefail$' "$script"
    bash "$script" --version >/dev/null
    bash "$script" --help >/dev/null
done

if grep -nE 'ufw[[:space:]]+--force[[:space:]]+reset|/tmp/wp-(single-)?deploy\.state|FLUSHDB|fastcgi_cache_path[[:space:]]+/var/cache/nginx' "${scripts[@]}"; then
    printf 'A prohibited high-risk pattern was found.\n' >&2
    exit 1
fi

grep -Fq "readonly METRICS_DB=\"\$STATE_DIR/metrics.sqlite3\"" "$repo_root/wp-shell.sh"
grep -Fq "readonly ENVIRONMENT_CONFIG_FILE=\"\$CONFIG_DIR/environment.v1\"" "$repo_root/wp-shell.sh"
grep -Fq "readonly WORDPRESS_LOCALE=\"\${WORDPRESS_LOCALE:-en_US}\"" "$repo_root/wp-shell.sh"
grep -Fq "fastcgi_pass unix:\$pool_socket;" "$repo_root/wp-shell.sh"
grep -Fq 'It intentionally excludes client IPs, cookies, and query strings.' "$repo_root/wp-shell.sh"
if grep -q 'install_site_wrapper' "$repo_root/wp-shell.sh"; then
    printf 'Per-domain command generation must not be reintroduced.\n' >&2
    exit 1
fi
if LC_ALL=C grep -nP '[^\x00-\x7F]' "${scripts[@]}"; then
    printf 'Non-ASCII text was found in terminal scripts.\n' >&2
    exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${scripts[@]}"
fi

printf 'Static checks passed.\n'
