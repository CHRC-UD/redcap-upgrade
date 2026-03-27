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
