#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
# shellcheck disable=SC1091
source "$repo_root/wp-shell.sh"

mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$test_root/site"
printf '<?php\n' > "$test_root/site/wp-config.php"
SITE_COUNT=1
SITE_DOMAINS[1]=example.com
SITE_PATHS[1]="$test_root/site"
SITE_PHP_VERSIONS[1]=8.3
SITE_MODES[1]=imported

restore_operation_status example.com > "$test_root/empty-status"
grep -Fq 'no restore operation journal' "$test_root/empty-status"
[[ ! -e "$RESTORE_STATE_DIR" ]]

if (restore_site 1 20260901-010101) > "$test_root/unconfirmed" 2>&1; then
    printf 'Restore ran without explicit confirmation.\n' >&2
    exit 1
fi
grep -Fq 'replace the site files and database' "$test_root/unconfirmed"
[[ ! -e "$RESTORE_STATE_DIR" ]]

current="$(restore_begin_operation example.com 20260901-010101 "$test_root/site" wp_example)"
journal="$current/journal.v1"
[[ "$current" == "$(restore_current_operation_dir example.com)" ]]
[[ "$(stat -c '%a' "$journal")" == 600 ]]
[[ "$(restore_journal_last_state "$journal")" == initialized ]]
[[ "$(b64_decode "$(restore_journal_value "$journal" wp-path)")" == "$test_root/site" ]]

# A non-terminal operation is an admission barrier. It must not be replaced
# by a second restore journal.
if restore_begin_operation example.com 20260901-020202 "$test_root/site" wp_example >/dev/null 2>&1; then
    printf 'A second restore replaced a non-terminal journal.\n' >&2
    exit 1
fi

if restore_journal_state "$journal" committed 'invalid state jump'; then
    printf 'Restore journal accepted an invalid state transition.\n' >&2
    exit 1
fi
restore_journal_state "$journal" source-ready
restore_journal_state "$journal" maintenance
restore_journal_state "$journal" safety-ready
restore_journal_state "$journal" files-applying 'fault after file mutation'
restore_state_requires_rollback "$(restore_journal_last_state "$journal")"
if restore_terminal_state "$(restore_journal_last_state "$journal")"; then exit 1; fi
restore_journal_append "$journal" safety-backup 20260902-030303
[[ "$(restore_journal_value "$journal" safety-backup)" == 20260902-030303 ]]
restore_journal_state "$journal" rollback-running
mkdir -p "$current/source-files"
printf 'disposable\n' > "$current/source-files/fixture"
restore_journal_state "$journal" rolled-back 'fixture recovered'
restore_terminal_state "$(restore_journal_last_state "$journal")"

# Starting the next operation archives the completed journal and creates one
# new current journal. The previous audit record is retained.
old_id="$(restore_journal_value "$journal" id)"
next="$(restore_begin_operation example.com 20260901-020202 "$test_root/site" wp_example)"
[[ "$next" == "$current" ]]
[[ -f "$(dirname "$current")/history/$old_id/journal.v1" ]]
[[ ! -e "$(dirname "$current")/history/$old_id/source-files" ]]
[[ "$(restore_journal_last_state "$next/journal.v1")" == initialized ]]

# State and field writers reject delimiters rather than creating ambiguous
# records. Journal details are encoded and no plain credential is emitted.
if restore_journal_append "$next/journal.v1" detail 'unsafe|record'; then exit 1; fi
restore_journal_state "$next/journal.v1" aborted 'password fixture-value was not logged as a field'
if grep -Fq 'password fixture-value' "$next/journal.v1"; then exit 1; fi

# A conservative unpacked-size admission check fails before extraction when
# the staging filesystem cannot retain a 256MB emergency reserve.
mkdir "$test_root/archive"
printf '<?php\n' > "$test_root/archive/wp-config.php"
tar -czf "$test_root/files.tar.gz" -C "$test_root/archive" .
python3 - "$test_root/duplicate-paths.tar.gz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    for name in ("wp-config.php", "./wp-config.php"):
        data = b"<?php\n"
        member = tarfile.TarInfo(name)
        member.size = len(data)
        archive.addfile(member, io.BytesIO(data))
PY
if validate_restore_archive "$test_root/duplicate-paths.tar.gz" >/dev/null 2>&1; then
    printf 'Restore accepted duplicate normalized archive paths.\n' >&2
    exit 1
fi
third="$(restore_begin_operation example.com 20260901-040404 "$test_root/site" wp_example)"
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 1000 900 100 90%% /\n'; }
if restore_stage_source "$test_root/files.tar.gz" "$third" >/dev/null 2>&1; then
    printf 'Restore staging ignored the low-disk admission guard.\n' >&2
    exit 1
fi
[[ ! -e "$third/source-files" ]]
unset -f df

# Never follow a substituted current-operation symlink when rotating or
# creating journals.
restore_journal_state "$third/journal.v1" aborted
fourth="$(restore_begin_operation example.com 20260901-050505 "$test_root/site" wp_example)"
restore_journal_state "$fourth/journal.v1" aborted
fourth_id="$(restore_journal_value "$fourth/journal.v1" id)"
ln -s "$test_root/site" "$(dirname "$fourth")/history/$fourth_id"
if restore_begin_operation example.com 20260901-060606 "$test_root/site" wp_example >/dev/null 2>&1; then
    printf 'Restore journal rotation followed a conflicting history symlink.\n' >&2
    exit 1
fi
rm -f -- "$(dirname "$fourth")/history/$fourth_id"
fifth="$(restore_begin_operation example.com 20260901-060606 "$test_root/site" wp_example)"
restore_journal_state "$fifth/journal.v1" aborted
rm -rf -- "$fifth"
ln -s "$test_root/site" "$fifth"
if restore_begin_operation example.com 20260901-070707 "$test_root/site" wp_example >/dev/null 2>&1; then
    printf 'Restore journal creation followed an unsafe current symlink.\n' >&2
    exit 1
fi
[[ -L "$fifth" ]]

printf 'Restore journal transitions, admission barrier, history, state classification, symlink rejection and low-disk tests passed.\n'
