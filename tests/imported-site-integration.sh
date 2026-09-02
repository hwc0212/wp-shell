#!/usr/bin/env bash
# Run only as root in a disposable container.
# shellcheck disable=SC1091,SC2016,SC2034,SC2317,SC2329

set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { printf 'This integration test requires a disposable root container.\n' >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/wp-shell-import-test.XXXXXX)"
domain="imported.example.com"
wp_path="/var/www/$domain/public"
site_user="wp_import_fixture"
events_file="/tmp/wp-shell-import-events"
fail_marker="/tmp/wp-shell-import-fail"

cleanup_import_test() {
    rm -rf -- "/var/www/$domain" "$test_root"
    rm -f -- "$events_file" "$fail_marker" /usr/local/bin/wp /usr/bin/php8.2
    userdel "$site_user" 2>/dev/null || true
}

export WP_SHELL_CONFIG_DIR="$test_root/config"
export WP_SHELL_STATE_DIR="$test_root/state"
export WP_SHELL_TEST_ROOT_WRITES=yes
source "$repo_root/wp-shell.sh"
trap cleanup_import_test EXIT
trap 'printf "Imported-site integration failed at line %s.\n" "$LINENO" >&2; [[ ! -s "$events_file" ]] || tail -80 "$events_file" >&2' ERR
install -d -m 0700 "$CONFIG_DIR" "$DATABASE_CONFIG_DIR" "$STATE_DIR"
install -d -m 0755 /etc/nginx/sites-enabled /var/www
cat > /etc/nginx/sites-enabled/unrelated.example.com <<'NGINX'
server {
    server_name unrelated.example.com;
    root /var/www/unrelated.example.com/public;
    fastcgi_pass unix:/run/php/php8.3-fpm.sock;
}
NGINX

getent group www-data >/dev/null || groupadd --system www-data
id www-data >/dev/null 2>&1 || useradd --system --gid www-data --home-dir /var/www --shell /usr/sbin/nologin www-data
useradd --system --user-group --home-dir "/var/www/$domain" --shell /usr/sbin/nologin "$site_user"
site_group="$(id -gn "$site_user")"

install -d -o "$site_user" -g "$site_group" -m 0750 "$wp_path/wp-includes"
printf '<?php // imported WordPress fixture\n' > "$wp_path/wp-load.php"
printf '<?php $wp_version = "6.8.2";\n' > "$wp_path/wp-includes/version.php"
cat > "$wp_path/wp-config.php" <<'PHP'
<?php
define( 'DB_NAME', 'fixture' );
define( 'WP_DEBUG', false );
PHP
chown -R "$site_user:$site_group" "/var/www/$domain"
chmod 0750 "$wp_path" "$wp_path/wp-includes"
chmod 0640 "$wp_path/wp-load.php" "$wp_path/wp-includes/version.php" "$wp_path/wp-config.php"

: > "$events_file"
chmod 0666 "$events_file"

# The fake PHP launcher preserves the production calling convention while the
# fake WP-CLI records the real EUID and wp-config.php mode seen by the
# non-root process.  This exercises sudo, Unix ownership and permissions.
install -m 0755 /dev/stdin /usr/bin/php8.2 <<'PHP_LAUNCHER'
#!/usr/bin/env bash
exec "$@"
PHP_LAUNCHER
install -m 0755 /dev/stdin /usr/local/bin/wp <<'WP_CLI'
#!/usr/bin/env bash
set -Eeuo pipefail
events_file=/tmp/wp-shell-import-events
wp_path=""
declare -a command_args=()
for argument in "$@"; do
    case "$argument" in
        --path=*) wp_path="${argument#--path=}" ;;
        --skip-plugins|--skip-themes|--no-color|--quiet) ;;
        *) command_args+=("$argument") ;;
    esac
done
[[ -n "$wp_path" ]]
command_name="${command_args[0]:-}"
subcommand="${command_args[1]:-}"
case "$command_name $subcommand" in
    'option get')
        [[ "${command_args[2]:-}" == home ]]
        printf 'https://imported.example.com\n'
        ;;
    'config set')
        key="${command_args[2]:-}"
        value="${command_args[3]:-}"
        printf 'wp|config set|%s|%s|%s|%s|%s\n' \
            "$key" "$(id -u)" "$(stat -c %a "$wp_path/wp-config.php")" \
            "$(stat -c %U "$wp_path/wp-config.php")" "$(stat -c %G "$wp_path/wp-config.php")" >> "$events_file"
        sed -i "/define( '$key',/d" "$wp_path/wp-config.php"
        printf "define( '%s', '%s' );\n" "$key" "$value" >> "$wp_path/wp-config.php"
        [[ "$key" != FAIL_MUTATION ]] || exit 42
        ;;
    'config delete')
        key="${command_args[2]:-}"
        printf 'wp|config delete|%s|%s|%s\n' "$key" "$(id -u)" "$(stat -c %a "$wp_path/wp-config.php")" >> "$events_file"
        sed -i "/define( '$key',/d" "$wp_path/wp-config.php"
        ;;
    'config create')
        [[ ! -e "$wp_path/wp-config.php" && ! -L "$wp_path/wp-config.php" ]]
        printf 'wp|config create|%s\n' "$(id -u)" >> "$events_file"
        printf '<?php // safely created fixture\n' > "$wp_path/wp-config.php"
        ;;
    'core is-installed')
        printf 'wp|core is-installed|%s\n' "$(id -u)" >> "$events_file"
        ;;
    'plugin is-active')
        printf 'wp|plugin is-active|%s\n' "$(id -u)" >> "$events_file"
        exit 1
        ;;
    *)
        printf 'Unexpected fake WP-CLI command: %s\n' "${command_args[*]}" >&2
        exit 2
        ;;
esac
WP_CLI

ENVIRONMENT_MODE=multi
DEFAULT_PHP_VERSION=8.2
ENVIRONMENT_UFW=no
import_existing_sites
[[ "$SITE_COUNT" -eq 1 ]]
[[ "${SITE_DOMAINS[1]}" == "$domain" ]]
[[ "${SITE_PHP_VERSIONS[1]}" == 8.2 ]]
[[ "${SITE_MODES[1]}" == imported ]]
[[ "$(site_run_user "$domain")" == "$site_user" ]]

# Keep this integration focused on the imported WordPress lifecycle.  The
# Nginx and certificate implementations have separate service integrations.
configure_acme_site() { printf 'deploy|acme\n' >> "$events_file"; }
issue_ssl_certificate() { printf 'deploy|certificate\n' >> "$events_file"; }
configure_https_site() { printf 'deploy|https\n' >> "$events_file"; }
memory_mb() { printf '2048'; }
eval "$(declare -f set_site_permissions | sed '1s/^set_site_permissions/original_set_site_permissions/')"
set_site_permissions() {
    printf 'deploy|permissions\n' >> "$events_file"
    original_set_site_permissions "$@"
}

: > "$events_file"
deploy_site 1
[[ "${SITE_MODES[1]}" == managed ]]
[[ "$(stat -c '%a %U %G' "$wp_path/wp-config.php")" == "640 root $site_group" ]]

# No full-tree hardening may occur before the config mutations, every mutation
# must run as the non-root site user through a 0660 window, and the final core
# check must precede final hardening.
first_event="$(head -n 1 "$events_file")"
[[ "$first_event" == deploy\|acme ]]
first_config_line="$(grep -n '^wp|config set|' "$events_file" | sed -n '1s/:.*//p')"
permissions_line="$(grep -n '^deploy|permissions$' "$events_file" | tail -n 1 | cut -d: -f1)"
final_core_line="$(grep -n '^wp|core is-installed|' "$events_file" | tail -n 1 | cut -d: -f1)"
[[ "$first_config_line" =~ ^[0-9]+$ && "$permissions_line" =~ ^[0-9]+$ && "$final_core_line" =~ ^[0-9]+$ ]]
((first_config_line < final_core_line && final_core_line < permissions_line))
if awk -F '|' '$1=="wp" && $2=="config set" && ($4==0 || $5!="660" || $6!="root") {bad=1} END {exit bad}' "$events_file"; then
    :
else
    printf 'A config mutation escaped the restricted non-root write window.\n' >&2
    exit 1
fi
[[ "$(grep -c '^wp|config set|' "$events_file")" -ge 5 ]]

# delete uses the same per-command write window.  create is permitted only
# when the exact validated target is absent, and its new file is immediately
# hardened by the same EXIT cleanup.
site_wp_cli "$domain" config set DELETE_FIXTURE true --raw
site_wp_cli "$domain" config delete DELETE_FIXTURE
[[ "$(stat -c '%a %U %G' "$wp_path/wp-config.php")" == "640 root $site_group" ]]
grep -Eq "^wp[|]config delete[|]DELETE_FIXTURE[|][1-9][0-9]*[|]660$" "$events_file"
mv "$wp_path/wp-config.php" "$test_root/existing-wp-config.php"
site_wp_cli "$domain" config create --dbname=fixture --dbuser=fixture
[[ "$(stat -c '%a %U %G' "$wp_path/wp-config.php")" == "640 root $site_group" ]]
grep -Eq '^wp[|]config create[|][1-9][0-9]*$' "$events_file"
rm "$wp_path/wp-config.php"
mv "$test_root/existing-wp-config.php" "$wp_path/wp-config.php"
chown root:"$site_group" "$wp_path/wp-config.php"
chmod 0640 "$wp_path/wp-config.php"

# A failed mutation may change contents, but ownership/mode must still close
# back to the hardened state before the error is returned to the caller.
if site_wp_cli "$domain" config set FAIL_MUTATION true --raw; then
    printf 'The injected WP-CLI failure was reported as success.\n' >&2
    exit 1
fi
[[ "$(stat -c '%a %U %G' "$wp_path/wp-config.php")" == "640 root $site_group" ]]

# Neither the path validator nor cleanup may follow a substituted symlink.
mv "$wp_path/wp-config.php" "$test_root/real-wp-config.php"
printf 'sentinel\n' > "$test_root/outside-sentinel"
ln -s "$test_root/outside-sentinel" "$wp_path/wp-config.php"
before_calls="$(wc -l < "$events_file")"
if site_wp_cli "$domain" config set SHOULD_NOT_RUN true --raw >/dev/null 2>&1; then
    printf 'A wp-config.php symlink was accepted.\n' >&2
    exit 1
fi
[[ "$(<"$test_root/outside-sentinel")" == sentinel ]]
[[ "$(wc -l < "$events_file")" -eq "$before_calls" ]]
rm "$wp_path/wp-config.php"
mv "$test_root/real-wp-config.php" "$wp_path/wp-config.php"
chown root:"$site_group" "$wp_path/wp-config.php"
chmod 0640 "$wp_path/wp-config.php"

# A second deploy must remain idempotently manageable with the same imported
# path, account, configured PHP version and final private-group permissions.
: > "$events_file"
deploy_site 1
[[ "$SITE_COUNT" -eq 1 && "${SITE_MODES[1]}" == managed && "${SITE_PHP_VERSIONS[1]}" == 8.2 ]]
[[ "$(stat -c '%a %U %G' "$wp_path/wp-config.php")" == "640 root $site_group" ]]
[[ "$(grep -c '^deploy|permissions$' "$events_file")" -eq 1 ]]

printf 'Imported discovery/deploy, non-root config writes, failure cleanup, symlink rejection and idempotency passed.\n'
