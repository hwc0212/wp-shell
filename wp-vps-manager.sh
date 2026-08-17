#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
    --help|-h|--version|-v)
        if [[ -x /usr/local/sbin/wp-shell ]]; then
            exec /usr/local/sbin/wp-shell "$1"
        fi
        exec bash "$script_dir/wp-shell.sh" "$1"
        ;;
esac
if [[ -x /usr/local/sbin/wp-shell ]]; then
    exec /usr/local/sbin/wp-shell legacy-vps "$@"
fi
exec bash "$script_dir/wp-shell.sh" legacy-vps "$@"
