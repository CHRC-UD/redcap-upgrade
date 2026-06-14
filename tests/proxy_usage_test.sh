#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/redcap_easy_upgrade.sh"

extract_function() {
  local fn="$1"
  awk -v fn="$fn" '
    $0 ~ ("^" fn "\\(\\) ?\\{") { printing=1 }
    printing { print }
    printing && $0 == "}" { exit }
  ' "$SCRIPT_PATH"
}

run_bash_test() {
  local name="$1" code="$2"
  if bash -c "$code"; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s\n' "$name" >&2
    return 1
  fi
}

run_bash_test "fetch_versions_json uses configured proxy" '
  set -euo pipefail
  tmpdir="$(mktemp -d)"
  trap '\''rm -rf "$tmpdir"'\'' EXIT

  cat > "$tmpdir/curl" <<'\''EOF'\''
#!/usr/bin/env bash
printf "%s\n" "$@" > "$TMPDIR/curl.args"
printf "{}"
EOF
  chmod +x "$tmpdir/curl"

  export PATH="$tmpdir:$PATH"
  export TMPDIR="$tmpdir"
  export REDCAP_UPGRADE_PROXY="http://proxy.example.com:3128"
  export VERSIONS_URL="https://example.test/versions.php"

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function build_curl_proxy_args)"'
'"$(extract_function fetch_versions_json)"'
FUNCS

  fetch_versions_json "1.2.3" >/dev/null
  grep -Fx -- "--proxy" "$tmpdir/curl.args" >/dev/null
  grep -Fx -- "http://proxy.example.com:3128" "$tmpdir/curl.args" >/dev/null
'

run_bash_test "fetch_versions_json falls back to default curl proxy behavior when unset" '
  set -euo pipefail
  tmpdir="$(mktemp -d)"
  trap '\''rm -rf "$tmpdir"'\'' EXIT

  cat > "$tmpdir/curl" <<'\''EOF'\''
#!/usr/bin/env bash
printf "%s\n" "$@" > "$TMPDIR/curl.args"
printf "{}"
EOF
  chmod +x "$tmpdir/curl"

  export PATH="$tmpdir:$PATH"
  export TMPDIR="$tmpdir"
  unset REDCAP_UPGRADE_PROXY || true
  export VERSIONS_URL="https://example.test/versions.php"

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function build_curl_proxy_args)"'
'"$(extract_function fetch_versions_json)"'
FUNCS

  fetch_versions_json "1.2.3" >/dev/null
  if grep -Fx -- "--proxy" "$tmpdir/curl.args" >/dev/null; then
    exit 1
  fi
'

run_bash_test "get_current_version rejects REDCap offline HTML as local database failure" '
  set -euo pipefail
  tmpdir="$(mktemp -d)"
  trap '\''rm -rf "$tmpdir"'\'' EXIT

  mkdir -p "$tmpdir/redcap"
  : > "$tmpdir/redcap/redcap_connect.php"

  cat > "$tmpdir/php" <<'\''EOF'\''
#!/usr/bin/env bash
cat <<'\''HTML'\''
<div>
  CRITICAL ERROR: REDCap server is offline!
  database.php could not connect to the database server.
</div>
HTML
exit 2
EOF
  chmod +x "$tmpdir/php"

  export PATH="$tmpdir:$PATH"
  export REDCAP_ROOT="$tmpdir/redcap"

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function is_redcap_version)"'
'"$(extract_function get_current_version)"'
FUNCS

  if get_current_version > "$tmpdir/out" 2> "$tmpdir/err"; then
    exit 1
  fi
  grep -F "Could not determine current REDCap version" "$tmpdir/err" >/dev/null
  grep -F "local REDCap app cannot reach its database" "$tmpdir/err" >/dev/null
  if grep -F "VUMC" "$tmpdir/err" >/dev/null; then
    exit 1
  fi
'

run_bash_test "get_current_version accepts a valid REDCap version" '
  set -euo pipefail
  tmpdir="$(mktemp -d)"
  trap '\''rm -rf "$tmpdir"'\'' EXIT

  mkdir -p "$tmpdir/redcap"
  : > "$tmpdir/redcap/redcap_connect.php"

  cat > "$tmpdir/php" <<'\''EOF'\''
#!/usr/bin/env bash
printf "17.0.8"
EOF
  chmod +x "$tmpdir/php"

  export PATH="$tmpdir:$PATH"
  export REDCAP_ROOT="$tmpdir/redcap"

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function is_redcap_version)"'
'"$(extract_function get_current_version)"'
FUNCS

  got="$(get_current_version)"
  test "$got" = "17.0.8"
'

run_bash_test "download_version_zip uses configured proxy" '
  set -euo pipefail
  tmpdir="$(mktemp -d)"
  trap '\''rm -rf "$tmpdir"'\'' EXIT

  cat > "$tmpdir/curl" <<'\''EOF'\''
#!/usr/bin/env bash
printf "%s\n" "$@" > "$TMPDIR/curl.args"
: > "$TMPDIR/upgrade.zip"
EOF
  chmod +x "$tmpdir/curl"

  export PATH="$tmpdir:$PATH"
  export TMPDIR="$tmpdir"
  export REDCAP_UPGRADE_PROXY="http://proxy.example.com:3128"
  export VERSIONS_URL="https://example.test/versions.php"

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function build_curl_proxy_args)"'
'"$(extract_function download_version_zip)"'
FUNCS

  download_version_zip "1.2.3" "user" "pass" "$tmpdir/upgrade.zip"
  grep -Fx -- "--proxy" "$tmpdir/curl.args" >/dev/null
  grep -Fx -- "http://proxy.example.com:3128" "$tmpdir/curl.args" >/dev/null
'

run_bash_test "fcontext_path_regex escapes REDCap version dots" '
  set -euo pipefail

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function fcontext_path_regex)"'
FUNCS

  got="$(fcontext_path_regex "/var/www/html/redcap/redcap_v17.0.1")"
  test "$got" = "/var/www/html/redcap/redcap_v17\\.0\\.1"
'

run_bash_test "selinux_management_enabled treats false as disabled" '
  set -euo pipefail

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function selinux_management_enabled)"'
FUNCS

  REDCAP_UPGRADE_MANAGE_SELINUX=false
  if selinux_management_enabled; then
    exit 1
  fi

  REDCAP_UPGRADE_MANAGE_SELINUX=true
  selinux_management_enabled
'

run_bash_test "http_smoke_check_enabled treats false as disabled" '
  set -euo pipefail

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function http_smoke_check_enabled)"'
FUNCS

  REDCAP_UPGRADE_HTTP_SMOKE_CHECK=false
  if http_smoke_check_enabled; then
    exit 1
  fi

  REDCAP_UPGRADE_HTTP_SMOKE_CHECK=true
  http_smoke_check_enabled
'

run_bash_test "remove_install_php_files true removes webroot and version installers" '
  set -euo pipefail
  tmpdir="$(mktemp -d)"
  trap '\''rm -rf "$tmpdir"'\'' EXIT

  mkdir -p "$tmpdir/redcap/redcap_v1.2.3" "$tmpdir/redcap/redcap_v1.2.4"
  : > "$tmpdir/redcap/install.php"
  : > "$tmpdir/redcap/redcap_v1.2.3/install.php"
  : > "$tmpdir/redcap/redcap_v1.2.4/install.php"

  export REDCAP_ROOT="$tmpdir/redcap"
  export REDCAP_UPGRADE_REMOVE_INSTALL_PHP=true

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function remove_install_php_files)"'
FUNCS

  remove_install_php_files >"$tmpdir/out"
  grep -F "Removed 3 REDCap install.php file(s)" "$tmpdir/out" >/dev/null
  test ! -e "$tmpdir/redcap/install.php"
  test ! -e "$tmpdir/redcap/redcap_v1.2.3/install.php"
  test ! -e "$tmpdir/redcap/redcap_v1.2.4/install.php"
'

run_bash_test "remove_install_php_files prompt keeps files when declined" '
  set -euo pipefail
  tmpdir="$(mktemp -d)"
  trap '\''rm -rf "$tmpdir"'\'' EXIT

  mkdir -p "$tmpdir/redcap/redcap_v1.2.3"
  : > "$tmpdir/redcap/install.php"
  : > "$tmpdir/redcap/redcap_v1.2.3/install.php"

  export REDCAP_ROOT="$tmpdir/redcap"
  export REDCAP_UPGRADE_REMOVE_INSTALL_PHP=prompt

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function remove_install_php_files)"'
FUNCS

  printf "n\n" | remove_install_php_files >"$tmpdir/out"
  grep -F "Detected 2 REDCap install.php file(s)" "$tmpdir/out" >/dev/null
  grep -F "Kept detected install.php files." "$tmpdir/out" >/dev/null
  test -e "$tmpdir/redcap/install.php"
  test -e "$tmpdir/redcap/redcap_v1.2.3/install.php"
'

run_bash_test "confirm_privileged_run warns non-root non-sudo users and allows confirmation" '
  set -euo pipefail
  TMPDIR="$(mktemp -d)"
  trap '\''rm -rf "$TMPDIR"'\'' EXIT

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function confirm_privileged_run)"'
FUNCS

  printf "y\n" | confirm_privileged_run "deploy" "1001" >"$TMPDIR/confirm.out" 2>&1
  grep -F -- "WARNING: This upgrade is normally run as root or with sudo." "$TMPDIR/confirm.out" >/dev/null
  grep -F -- "Current user deploy must already have permission" "$TMPDIR/confirm.out" >/dev/null

  if printf "n\n" | confirm_privileged_run "deploy" "1001" >/dev/null 2>&1; then
    exit 1
  fi
'

run_bash_test "confirm_privileged_run does not warn when effective uid is root" '
  set -euo pipefail
  TMPDIR="$(mktemp -d)"
  trap '\''rm -rf "$TMPDIR"'\'' EXIT

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function confirm_privileged_run)"'
FUNCS

  confirm_privileged_run "root" "0" >"$TMPDIR/root.out" 2>&1
  test ! -s "$TMPDIR/root.out"

  confirm_privileged_run "deploy" "0" >"$TMPDIR/sudo.out" 2>&1
  test ! -s "$TMPDIR/sudo.out"
'

run_bash_test "install_version_tree succeeds without rollback copy" '
  set -euo pipefail
  tmpdir="$(mktemp -d)"
  trap '\''rm -rf "$tmpdir"'\'' EXIT

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function install_version_tree)"'
FUNCS

  _TMPFILES=()
  mkdir -p "$tmpdir/src/ControlCenter"
  printf "<?php\n" > "$tmpdir/src/ControlCenter/index.php"

  install_version_tree "$tmpdir/src" "$tmpdir/redcap_v16.0.22" >/dev/null
  test -f "$tmpdir/redcap_v16.0.22/ControlCenter/index.php"
'

run_bash_test "set_fcontext_tree_rule registers exact and recursive rules" '
  set -euo pipefail
  tmpdir="$(mktemp -d)"
  trap '\''rm -rf "$tmpdir"'\'' EXIT

  cat > "$tmpdir/semanage" <<'\''EOF'\''
#!/usr/bin/env bash
printf "%s\n" "$*" >> "$TMPDIR/semanage.calls"
EOF
  chmod +x "$tmpdir/semanage"

  export PATH="$tmpdir:$PATH"
  export TMPDIR="$tmpdir"

  source /dev/stdin <<'\''FUNCS'\''
'"$(extract_function set_fcontext_rule)"'
'"$(extract_function set_fcontext_tree_rule)"'
FUNCS

  set_fcontext_tree_rule httpd_sys_rw_content_t "/var/www/html/redcap/temp"

  grep -Fx -- "fcontext -a -t httpd_sys_rw_content_t /var/www/html/redcap/temp" "$tmpdir/semanage.calls" >/dev/null
  grep -Fx -- "fcontext -a -t httpd_sys_rw_content_t /var/www/html/redcap/temp(/.*)?" "$tmpdir/semanage.calls" >/dev/null
'
