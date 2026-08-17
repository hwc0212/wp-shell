#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

test_migration() {
    local legacy_dir="$1" destination="$2"
    install -d "$legacy_dir/20260817-010000" "$destination/20260817-010000"
    printf 'legacy-only\n' > "$legacy_dir/20260817-010000/files.tar.gz"
    printf 'legacy-manifest\n' > "$legacy_dir/20260817-010000/manifest.txt"
    printf 'new-manifest\n' > "$destination/20260817-010000/manifest.txt"

    migrate_legacy_backups "$legacy_dir" "$destination"

    [[ -f "$destination/20260817-010000/files.tar.gz" ]]
    [[ "$(<"$destination/20260817-010000/manifest.txt")" == "new-manifest" ]]
    [[ -f "$destination/.legacy-backups-imported" ]]
    [[ -d "$legacy_dir" ]]
}

(
    source "$repo_root/wp-vps-manager.sh"
    [[ "$(site_cache_dir example.com)" == "/var/www/example.com/cache" ]]
    [[ "$(site_backup_dir example.com)" == "/var/www/example.com/backups" ]]
    test_migration "$test_root/legacy-multi" "$test_root/new-multi"
)

(
    source "$repo_root/deploy-single-wordpress.sh"
    DOMAIN="single.example.com"
    [[ "$(site_cache_dir)" == "/var/www/single.example.com/cache" ]]
    [[ "$(site_backup_dir)" == "/var/www/single.example.com/backups" ]]
    test_migration "$test_root/legacy-single" "$test_root/new-single"
)

printf '站点存储布局与旧备份迁移测试通过。\n'
