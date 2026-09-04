#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/wp-shell-v11.sh"

bash -n "$SCRIPT"
[[ "$($SCRIPT --version)" == "wp-shell 11.0.0-dev" ]]

help_output="$($SCRIPT --help)"
grep -Fq "EXPERIMENTAL V11 DEVELOPMENT - NOT FOR PRODUCTION" <<<"$help_output"
grep -Fq "/usr/local/sbin/wp-shell-v11 and never replaces /usr/local/sbin/wp-shell" <<<"$help_output"
grep -Fq "sudo env WP_SHELL_V11_EXPERIMENTAL=yes wp-shell-v11 COMMAND" <<<"$help_output"
grep -Fq "sudo wp-shell-v11 capacity" <<<"$help_output"
grep -Fq "site DOMAIN workers N [--confirm]" <<<"$help_output"
grep -Fq "migrate v10 [--confirm]" <<<"$help_output"
grep -Fq "metrics collect                  Retired compatibility no-op; never writes" <<<"$help_output"

set +e
blocked_output="$($SCRIPT install 2>&1)"
blocked_status=$?
set -e
[[ $blocked_status -eq 1 ]]
grep -Fq "Mutating commands are blocked unless WP_SHELL_V11_EXPERIMENTAL=yes" <<<"$blocked_output"

install_body="$(awk '/^install_self\(\)/,/^}/' "$SCRIPT")"
grep -Fq "write_managed_file \"\$MANAGED_SCRIPT\"" <<<"$install_body"
if grep -Eq '/usr/local/(bin|sbin)/(wp-shell|wp-vps-manager|wp-single-manager)' <<<"$install_body"; then
    printf 'v11 install_self must not replace stable v10 entry points or wrappers.\n' >&2
    exit 1
fi

if grep -Eq '^init_metrics_database\(\)|^collect_metrics\(\)|^install_metrics_timer\(\)|^dashboard\(\)|^metrics_report\(\)|^analyze_metrics\(\)|^apply_tuning\(\)' "$SCRIPT"; then
    printf 'v11 S1 must not retain the legacy metrics/dashboard/automatic-tuning runtime.\n' >&2
    exit 1
fi

[[ "$(sha256sum "$ROOT_DIR/wp-shell.sh" | awk '{print $1}')" == 926632c0bc629127f1b196c6ab64b62c519d17ad06bc7dae83cd464868a6a302 ]]
[[ "$(sha256sum "$ROOT_DIR/legacy/wp-shell-v10.0.4.sh" | awk '{print $1}')" == 926632c0bc629127f1b196c6ab64b62c519d17ad06bc7dae83cd464868a6a302 ]]

printf 'v11 bootstrap safety checks passed.\n'
