#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
source "$repo_root/wp-shell.sh"

test_migration() {
    local legacy_dir="$1" destination="$2"
    install -d "$legacy_dir/20260817-010000" "$destination/20260817-010000"
    printf 'legacy-only\n' > "$legacy_dir/20260817-010000/files.tar.gz"
    printf 'legacy-manifest\n' > "$legacy_dir/20260817-010000/manifest.txt"
    printf 'new-manifest\n' > "$destination/20260817-010000/manifest.txt"
    migrate_legacy_backups "$legacy_dir" "$destination"
    [[ -f "$destination/20260817-010000/files.tar.gz" ]]
    [[ "$(<"$destination/20260817-010000/manifest.txt")" == "new-manifest" ]]
    find "$destination" -maxdepth 1 -name '.legacy-backups-imported-*' | grep -q .
    [[ -d "$legacy_dir" ]]
}

[[ "$(site_cache_dir example.com)" == "/var/www/example.com/cache" ]]
[[ "$(site_backup_dir example.com)" == "/var/www/example.com/backups" ]]
[[ "$(site_wp_cli_home example.com)" == "/var/www/example.com/.wp-cli" ]]
test_migration "$test_root/legacy" "$test_root/new"

printf 'Site storage layout and backup migration tests passed.\n'
