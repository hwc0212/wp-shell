#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts=(
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

if grep -nE 'ufw[[:space:]]+--force[[:space:]]+reset|/tmp/wp-(single-)?deploy\.state|FLUSHDB|php-status|php-ping|apt-cache[[:space:]]+policy|fastcgi_cache_path[[:space:]]+/var/cache/nginx' "${scripts[@]}"; then
    printf '发现已禁止的高风险模式。\n' >&2
    exit 1
fi

grep -Fq "if [[ ! -f \"/var/www/\$DOMAIN/public/wp-config.php\" ]]; then" "$repo_root/deploy-single-wordpress.sh"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${scripts[@]}"
fi

printf '静态检查通过。\n'
