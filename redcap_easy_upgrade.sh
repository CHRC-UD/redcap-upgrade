#!/usr/bin/env bash
# =============================================================================
# redcap_easy_upgrade.sh
# =============================================================================
# A command-line equivalent of REDCap's web-based "Easy Upgrade", designed
# to be run as a privileged admin user (root) rather than the web server user.
#
# What it does — in order:
#   1. Reads the current REDCap version from the database (via redcap_connect.php)
#   2. Fetches available newer versions from the VUMC consortium endpoint
#   3. Prompts you to select a version (or pass one as an argument)
#   4. Downloads the upgrade zip from VUMC using your Community credentials
#   5. Extracts and installs the redcap_v<VERSION>/ directory
#   6. Generates and executes the upgrade SQL (same as upgrade.php)
#   7. Applies owner/group and SELinux labels for the new version directory
#   8. Validates filesystem labels and HTTP reachability before cleanup
#
# Requirements:
#   - bash 4+, php (CLI), curl, python3, unzip, mysql (CLI)
#   - Must NOT be run as the web server user (apache, www-data, etc.)
#   - A valid VUMC REDCap Community account to download the upgrade zip
#   - MySQL user with CREATE, DROP, ALTER, REFERENCES privileges on the REDCap db
#     (the script auto-detects redcap_updates_user from redcap_config if configured)
#
# Usage:
#   ./redcap_easy_upgrade.sh [OPTIONS] [VERSION]
#
#   VERSION   Optional target version, e.g. 15.5.36.
#             If omitted, a list of available versions is shown for selection.
#
# Options:
#   --check-versions   List versions newer than your current install, then exit.
#   --skip-download    Skip download/extract; use an already-present redcap_v* directory.
#   --dry-run          Generate the upgrade SQL and print it, but do not execute it.
#   -h, --help         Show this help text.
#
# Credential resolution order (first non-empty value wins):
#   MySQL host/port/db  →  REDCAP_UPGRADE_MYSQL_* vars below  →  database.php (auto)
#   MySQL user/pass     →  REDCAP_UPGRADE_MYSQL_* vars below  →  redcap_config auto-detect  →  prompt
#   VUMC credentials    →  REDCAP_COMMUNITY_* vars below  →  prompt
#
# Examples:
#   # Interactive — shows available versions, prompts for everything
#   sudo ./redcap_easy_upgrade.sh
#
#   # Upgrade to a specific version non-interactively
#   sudo REDCAP_COMMUNITY_USER=me REDCAP_COMMUNITY_PASSWORD=s3cr3t \
#        ./redcap_easy_upgrade.sh 15.5.36
#
#   # Preview the upgrade SQL without touching the database
#   sudo ./redcap_easy_upgrade.sh --dry-run 15.5.36
#
#   # Check what versions are available for your install
#   sudo ./redcap_easy_upgrade.sh --check-versions
# =============================================================================

# =============================================================================
# CONFIGURATION
# =============================================================================
# Site-specific settings live in redcap_easy_upgrade.conf (not committed).
# Copy redcap_easy_upgrade.conf.example to redcap_easy_upgrade.conf and edit.
#
# Resolution order for every variable (first non-empty value wins):
#   1. Environment variable exported before calling this script
#   2. Value set in redcap_easy_upgrade.conf
#   3. Built-in default below
#   4. Auto-detection from database.php / redcap_config (where supported)
#   5. Interactive prompt
# =============================================================================

# ── Resolve script directory (needed for conf file path and log default) ──────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source site config file if present ────────────────────────────────────────
_CONF_FILE="${_SCRIPT_DIR}/redcap_easy_upgrade.conf"
if [[ -f "$_CONF_FILE" ]]; then
  # shellcheck source=redcap_easy_upgrade.conf.example
  source "$_CONF_FILE"
else
  echo "NOTE: No config file found at ${_CONF_FILE}"
  echo "      Copy redcap_easy_upgrade.conf.example to redcap_easy_upgrade.conf"
  echo "      and edit it to match your environment."
  echo ""
fi

# ── Apply built-in defaults for anything left blank in the conf ───────────────
# These run AFTER sourcing so an empty value in the conf falls through to the
# default here (a non-empty conf value or pre-exported env var wins).
[[ -z "${REDCAP_ROOT:-}"                    ]] && REDCAP_ROOT="/var/www/html/redcap"
[[ -z "${UPGRADE_LOG_DIR:-}"                ]] && UPGRADE_LOG_DIR="${_SCRIPT_DIR}/logs"
[[ -z "${REDCAP_UPGRADE_FORBIDDEN_USERS:-}" ]] && REDCAP_UPGRADE_FORBIDDEN_USERS="apache www-data wwwrun nginx"
[[ -z "${REDCAP_UPGRADE_MANAGE_SELINUX:-}"  ]] && REDCAP_UPGRADE_MANAGE_SELINUX="true"
[[ -z "${REDCAP_UPGRADE_WRITABLE_PATHS:-}"  ]] && REDCAP_UPGRADE_WRITABLE_PATHS="temp edocs file_repository upload uploads cache"
[[ -z "${REDCAP_UPGRADE_HTTP_BASE_URL:-}"   ]] && REDCAP_UPGRADE_HTTP_BASE_URL=""
# All other vars (credentials, MySQL, SSL, proxy) default to empty — prompts or
# auto-detection handle them later in the script.

# =============================================================================
# END OF CONFIGURATION
# Do not edit below this line unless you know what you are doing.
# =============================================================================

set -euo pipefail

VERSIONS_URL="https://redcap.vumc.org/plugins/redcap_consortium/versions.php"
FORBIDDEN_USERS="${REDCAP_UPGRADE_FORBIDDEN_USERS:-apache www-data wwwrun nginx}"
DRY_RUN=false
CHECK_VERSIONS=false
SKIP_DOWNLOAD=false
TARGET_VERSION=""

# ── Parse arguments ────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --check-versions) CHECK_VERSIONS=true ;;
    --skip-download)  SKIP_DOWNLOAD=true ;;
    --dry-run)        DRY_RUN=true ;;
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p } }' "$0"
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $arg" >&2; exit 1 ;;
    *)
      if [[ "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        TARGET_VERSION="$arg"
      else
        echo "ERROR: Unexpected argument: $arg" >&2; exit 1
      fi
      ;;
  esac
done

# ── Safety: refuse to run as web server user ───────────────────────────────────
RUN_USER="${RUN_USER:-$(whoami 2>/dev/null || id -un 2>/dev/null)}"
for u in $FORBIDDEN_USERS; do
  if [[ "$RUN_USER" == "$u" ]]; then
    echo "ERROR: Do not run as the web server user ($u). Use root or a dedicated admin user." >&2
    exit 1
  fi
done

if [[ ! -d "$REDCAP_ROOT" ]]; then
  echo "ERROR: REDCAP_ROOT is not a directory: $REDCAP_ROOT" >&2
  exit 1
fi

# ── Temp file cleanup ──────────────────────────────────────────────────────────
_TMPFILES=()
_cleanup() { rm -rf "${_TMPFILES[@]}" 2>/dev/null || true; }
trap _cleanup EXIT

# ── Logging setup ──────────────────────────────────────────────────────────────
# Tee all stdout + stderr to a timestamped log file in $UPGRADE_LOG_DIR.
# Interactive read prompts are unaffected (they read from stdin).
# Passwords typed at "-s" prompts go to stdin only and are never written here.
mkdir -p "$UPGRADE_LOG_DIR" 2>/dev/null || {
  echo "WARNING: Could not create log directory: $UPGRADE_LOG_DIR — logging to stdout only." >&2
}
if [[ -d "$UPGRADE_LOG_DIR" ]]; then
  LOG_FILE="$UPGRADE_LOG_DIR/upgrade_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "┌─────────────────────────────────────────────────────────────────────────────"
  echo "│  Log file: $LOG_FILE"
  echo "└─────────────────────────────────────────────────────────────────────────────"
  echo ""
fi

# ── Get the current REDCap version from the database (via redcap_connect.php) ─
# This mirrors Upgrade::fetchREDCapVersionUpdatesList() which passes REDCAP_VERSION.
get_current_version() {
  local v=""
  if command -v php >/dev/null 2>&1 && [[ -f "$REDCAP_ROOT/redcap_connect.php" ]]; then
    v="$(cd "$REDCAP_ROOT" && php -d display_errors=0 -r '
      define("REDCAP_CONNECT_NONVERSIONED", true);
      @require "redcap_connect.php";
      if (isset($redcap_version) && preg_match("/^[0-9]+\.[0-9]+\.[0-9]+$/", $redcap_version)) {
        echo $redcap_version;
      }
    ' 2>/dev/null || true)"
  fi
  printf '%s' "${v:-0.0.0}"
}

# ── Read MySQL credentials from database.php + redcap_config ──────────────────
# Mirrors what the PHP Easy Upgrade does:
#   - Host/db/ssl come from database.php
#   - If redcap_updates_user is configured in redcap_config, use that user
#     (with its encrypted password decrypted via Cryptor + salt), otherwise
#     fall back to the main database.php credentials.
# Outputs AUTO_MYSQL_* variables as shell assignments for eval.
get_db_credentials() {
  local root="$1"
  [[ -f "$root/database.php" ]] || return 1
  PHPRC_ROOT="$root" php -d display_errors=0 2>/dev/null <<'PHPEOF'
<?php
$root = getenv('PHPRC_ROOT');
require $root . '/database.php';

// Load Cryptor from any installed REDCap version
foreach (glob($root . '/redcap_v*/Libraries/Cryptor.php') as $f) {
    require_once $f; break;
}

// Parse host and port out of $hostname (REDCap allows "host:port" format)
$mysql_host = preg_replace('/:\d+$/', '', $hostname);
$mysql_port = 3306;
if (preg_match('/:(\d+)$/', $hostname, $m)) $mysql_port = (int)$m[1];

// Connect with main credentials to read redcap_config.
// Use SSL if database.php defines $db_ssl_ca (mirrors redcap_connect.php behaviour).
$final_user = $username;
$final_pass = $password;
$conn = false;
if (!empty($db_ssl_ca)) {
    defined("MYSQLI_CLIENT_SSL_DONT_VERIFY_SERVER_CERT") or define("MYSQLI_CLIENT_SSL_DONT_VERIFY_SERVER_CERT", 64);
    $conn = @mysqli_init();
    if ($conn) {
        @mysqli_options($conn, MYSQLI_OPT_SSL_VERIFY_SERVER_CERT, true);
        @mysqli_ssl_set($conn,
            !empty($db_ssl_key)  ? $db_ssl_key  : null,
            !empty($db_ssl_cert) ? $db_ssl_cert : null,
            $db_ssl_ca,
            !empty($db_ssl_capath)  ? $db_ssl_capath  : null,
            !empty($db_ssl_cipher)  ? $db_ssl_cipher  : null
        );
        $ssl_flags = (isset($db_ssl_verify_server_cert) && $db_ssl_verify_server_cert)
            ? MYSQLI_CLIENT_SSL
            : MYSQLI_CLIENT_SSL_DONT_VERIFY_SERVER_CERT;
        if (!@mysqli_real_connect($conn, $mysql_host, $username, $password, $db, $mysql_port, null, $ssl_flags)) {
            $conn = false;
        }
    }
} else {
    $conn = @mysqli_connect($mysql_host, $username, $password, $db, $mysql_port);
}
if ($conn) {
    $q = mysqli_query($conn, "SELECT field_name, value FROM redcap_config
        WHERE field_name IN ('redcap_updates_user','redcap_updates_password','redcap_updates_password_encrypted')");
    $cfg = [];
    while ($row = mysqli_fetch_assoc($q)) $cfg[$row['field_name']] = $row['value'];
    $upg_user = $cfg['redcap_updates_user'] ?? '';
    $upg_pass = $cfg['redcap_updates_password'] ?? '';
    $upg_enc  = ($cfg['redcap_updates_password_encrypted'] ?? '0') === '1';
    if ($upg_user !== '') {
        $final_user = $upg_user;
        if ($upg_enc && $upg_pass !== '' && class_exists('Cryptor')) {
            try {
                $dec = Cryptor::Decrypt($upg_pass, $salt);
                if ($dec !== false) $final_pass = $dec;
            } catch (Exception $e) {}
        } else {
            $final_pass = $upg_pass;
        }
    }
}

echo 'AUTO_MYSQL_HOST=' . escapeshellarg($mysql_host) . "\n";
echo 'AUTO_MYSQL_PORT=' . escapeshellarg((string)$mysql_port) . "\n";
echo 'AUTO_MYSQL_DB='   . escapeshellarg($db)          . "\n";
echo 'AUTO_MYSQL_USER=' . escapeshellarg($final_user)  . "\n";
echo 'AUTO_MYSQL_PASS=' . escapeshellarg($final_pass)  . "\n";
if (!empty($db_ssl_ca))   echo 'AUTO_MYSQL_SSL_CA='   . escapeshellarg($db_ssl_ca)   . "\n";
if (!empty($db_ssl_cert)) echo 'AUTO_MYSQL_SSL_CERT=' . escapeshellarg($db_ssl_cert) . "\n";
if (!empty($db_ssl_key))  echo 'AUTO_MYSQL_SSL_KEY='  . escapeshellarg($db_ssl_key)  . "\n";
PHPEOF
}

# ── Fetch available versions JSON from endpoint ────────────────────────────────
build_curl_proxy_args() {
  local -a proxy_args=()
  if [[ -n "${REDCAP_UPGRADE_PROXY:-}" ]]; then
    proxy_args+=(--proxy "$REDCAP_UPGRADE_PROXY")
  fi
  printf '%s\n' "${proxy_args[@]}"
}

fetch_versions_json() {
  local current="$1"
  local -a curl_args=()
  while IFS= read -r arg; do
    [[ -n "$arg" ]] && curl_args+=("$arg")
  done < <(build_curl_proxy_args)
  curl "${curl_args[@]}" -fsS --connect-timeout 20 "${VERSIONS_URL}?current_version=${current}" 2>/dev/null
}

# ── Print versions table from a JSON file ─────────────────────────────────────
print_versions() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
for branch, label in [("lts", "LTS"), ("std", "Standard")]:
    items = d.get(branch, [])
    if not items:
        continue
    print(label + ":")
    for v in items:
        notes = (v.get("release_notes") or "")[:70]
        print("  %-12s  %-12s  %s" % (
            v.get("version_number", ""),
            v.get("release_date", ""),
            notes
        ))
    print()
PY
}

# ── Get ordered version list from JSON file (LTS first, then std) ─────────────
# Outputs tab-separated "version\tbranch" lines, e.g. "15.5.36\tlts"
get_version_list() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
for branch in ("lts", "std"):
    for v in d.get(branch, []):
        ver = v.get("version_number", "")
        if ver:
            print("%s\t%s" % (ver, branch))
PY
}

# ── Get current_branch from JSON ("lts" or "std") ─────────────────────────────
# The endpoint includes a "current_branch" key indicating which branch the
# current running version belongs to (same field the PHP UI reads).
get_current_branch() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get("current_branch", ""))
PY
}

# ── Download a version zip from the VUMC endpoint ─────────────────────────────
# POST params (mirrors Upgrade::performOneClickUpgrade): username, password, version
download_version_zip() {
  local version="$1" comm_user="$2" comm_pass="$3" zip_file="$4"
  local -a curl_args=()
  while IFS= read -r arg; do
    [[ -n "$arg" ]] && curl_args+=("$arg")
  done < <(build_curl_proxy_args)
  curl "${curl_args[@]}" -sS --connect-timeout 60 --max-time 300 \
    --data-urlencode "username=$comm_user" \
    --data-urlencode "password=$comm_pass" \
    --data-urlencode "version=$version" \
    -o "$zip_file" \
    "$VERSIONS_URL"
}

# ── Install and filesystem helpers ───────────────────────────────────────────
reference_version_owner_group() {
  local current_dir="$REDCAP_ROOT/redcap_v$CURRENT_VERSION"
  if [[ "$CURRENT_VERSION" != "$TARGET_VERSION" && -d "$current_dir" ]]; then
    stat -c '%u:%g' "$current_dir"
    return 0
  fi

  local owner_group=""
  owner_group="$(
    find "$REDCAP_ROOT" -maxdepth 1 -type d -name 'redcap_v*' ! -name "redcap_v$TARGET_VERSION" \
      -printf '%u:%g\n' 2>/dev/null | sort | uniq -c | sort -rn | awk 'NR == 1 { print $2 }'
  )"
  if [[ -n "$owner_group" ]]; then
    printf '%s\n' "$owner_group"
  else
    stat -c '%u:%g' "$REDCAP_ROOT"
  fi
}

install_version_tree() {
  local src_dir="$1" dst_dir="$2"
  local stamp staging backup_dir=""
  stamp="$(date +%Y%m%d_%H%M%S)"
  staging="${dst_dir}.install.${stamp}.$$"

  echo "Installing with metadata-preserving copy..."
  mkdir -p "$staging"
  _TMPFILES+=("$staging")

  if command -v rsync >/dev/null 2>&1; then
    echo "  Using: rsync -aAX"
    rsync -aAX "$src_dir"/ "$staging"/
  else
    echo "  rsync not found; using: cp -a"
    cp -a "$src_dir"/. "$staging"/
  fi

  if [[ -d "$dst_dir" ]]; then
    backup_dir="${dst_dir}.pre-upgrade.${stamp}"
    echo "Preserving existing version directory as rollback copy: $backup_dir"
    mv "$dst_dir" "$backup_dir"
  fi

  if ! mv "$staging" "$dst_dir"; then
    echo "ERROR: Failed to move staged install into place: $dst_dir" >&2
    if [[ -n "$backup_dir" && -d "$backup_dir" && ! -e "$dst_dir" ]]; then
      echo "Restoring previous directory from rollback copy: $backup_dir" >&2
      mv "$backup_dir" "$dst_dir"
    fi
    return 1
  fi

  echo "Installed: $dst_dir"
  [[ -n "$backup_dir" ]] && echo "Rollback copy retained: $backup_dir"
  return 0
}

sync_version_owner_group() {
  local version_dir="$1"
  local owner_group
  owner_group="$(reference_version_owner_group)"
  echo "Matching owner/group to existing REDCap version directories: $owner_group"
  chown -R "$owner_group" "$version_dir"
}

selinux_mode() {
  command -v getenforce >/dev/null 2>&1 || return 1
  getenforce 2>/dev/null || return 1
}

selinux_active() {
  local mode
  mode="$(selinux_mode 2>/dev/null || true)"
  [[ "$mode" == "Enforcing" || "$mode" == "Permissive" ]]
}

selinux_management_enabled() {
  case "${REDCAP_UPGRADE_MANAGE_SELINUX,,}" in
    0|false|no|off|disabled)
      return 1 ;;
    *)
      return 0 ;;
  esac
}

selinux_type() {
  local path="$1" context
  context="$(stat -c '%C' "$path" 2>/dev/null || true)"
  [[ -n "$context" && "$context" == *:*:* ]] || return 1
  printf '%s\n' "$context" | cut -d: -f3
}

set_fcontext_rule() {
  local type="$1" path_regex="$2"
  semanage fcontext -d "$path_regex" 2>/dev/null || true
  semanage fcontext -a -t "$type" "$path_regex" 2>/dev/null || \
    semanage fcontext -m -t "$type" "$path_regex"
}

set_fcontext_tree_rule() {
  local type="$1" path_regex="$2"
  set_fcontext_rule "$type" "$path_regex"
  set_fcontext_rule "$type" "${path_regex}(/.*)?"
}

fcontext_path_regex() {
  local path="$1"
  printf '%s\n' "${path//./\\.}"
}

existing_writable_paths() {
  local rel path
  for rel in $REDCAP_UPGRADE_WRITABLE_PATHS; do
    [[ -z "$rel" || "$rel" == /* || "$rel" == *".."* ]] && continue
    path="$REDCAP_ROOT/$rel"
    [[ -e "$path" ]] && printf '%s\n' "$path"
  done
}

apply_selinux_labels() {
  local version_dir="$1"
  selinux_management_enabled || {
    echo "SELinux management disabled by REDCAP_UPGRADE_MANAGE_SELINUX=$REDCAP_UPGRADE_MANAGE_SELINUX; skipping label application."
    return 0
  }
  selinux_active || {
    echo "SELinux: inactive or unavailable; skipping label application."
    return 0
  }

  local mode
  mode="$(selinux_mode)"
  echo "Applying SELinux labels for $version_dir (mode: $mode)..."

  if command -v semanage >/dev/null 2>&1 && command -v restorecon >/dev/null 2>&1; then
    local version_regex
    version_regex="$(fcontext_path_regex "$version_dir")"

    echo "  Registering persistent fcontext rules with semanage..."
    set_fcontext_tree_rule httpd_sys_content_t "$version_regex"

    local writable_path
    while IFS= read -r writable_path; do
      echo "  Registering writable fcontext: $writable_path -> httpd_sys_rw_content_t"
      set_fcontext_tree_rule httpd_sys_rw_content_t "$(fcontext_path_regex "$writable_path")"
    done < <(existing_writable_paths)

    echo "  Restoring contexts with restorecon..."
    restorecon -RFv "$version_dir"
    while IFS= read -r writable_path; do
      restorecon -RFv "$writable_path"
    done < <(existing_writable_paths)
  elif command -v chcon >/dev/null 2>&1; then
    echo "  WARNING: semanage/restorecon unavailable; using chcon fallback."
    echo "  WARNING: chcon labels are not persistent across a filesystem relabel."
    chcon -R -t httpd_sys_content_t "$version_dir"

    local writable_path
    while IFS= read -r writable_path; do
      echo "  Applying writable label: $writable_path -> httpd_sys_rw_content_t"
      chcon -R -t httpd_sys_rw_content_t "$writable_path"
    done < <(existing_writable_paths)
  else
    echo "ERROR: SELinux is active, but semanage/restorecon or chcon is not available." >&2
    return 1
  fi
}

infer_http_base_url() {
  if [[ -n "$REDCAP_UPGRADE_HTTP_BASE_URL" ]]; then
    printf '%s\n' "${REDCAP_UPGRADE_HTTP_BASE_URL%/}"
    return 0
  fi

  if [[ "$REDCAP_ROOT" == "/var/www/html" ]]; then
    printf '%s\n' "http://127.0.0.1"
  elif [[ "$REDCAP_ROOT" == /var/www/html/* ]]; then
    printf '%s/%s\n' "http://127.0.0.1" "${REDCAP_ROOT#/var/www/html/}"
  else
    return 1
  fi
}

validation_fail() {
  local message="$1"
  local version_regex
  version_regex="$(fcontext_path_regex "$VERSION_DIR")"
  echo ""
  echo "ERROR: Post-upgrade validation failed: $message" >&2
  echo "" >&2
  echo "Remediation:" >&2
  echo "  1. Inspect the path and labels shown above." >&2
  if selinux_management_enabled; then
    echo "  2. Ensure persistent SELinux rules exist, for example:" >&2
    echo "       semanage fcontext -a -t httpd_sys_content_t '${version_regex}(/.*)?'" >&2
    echo "       restorecon -RFv '$VERSION_DIR'" >&2
    echo "  3. Keep writable REDCap paths labeled httpd_sys_rw_content_t:" >&2
    echo "       REDCAP_UPGRADE_WRITABLE_PATHS=\"$REDCAP_UPGRADE_WRITABLE_PATHS\"" >&2
    echo "  4. If the HTTP smoke URL is wrong, set REDCAP_UPGRADE_HTTP_BASE_URL in redcap_easy_upgrade.conf." >&2
  else
    echo "  2. SELinux management is disabled by REDCAP_UPGRADE_MANAGE_SELINUX=$REDCAP_UPGRADE_MANAGE_SELINUX." >&2
    echo "  3. If the HTTP smoke URL is wrong, set REDCAP_UPGRADE_HTTP_BASE_URL in redcap_easy_upgrade.conf." >&2
  fi
  echo "" >&2
  return 1
}

validate_post_upgrade() {
  local version_dir="$1"
  local controlcenter_index="$version_dir/ControlCenter/index.php"
  local version_type index_type writable_path writable_type smoke_base smoke_url http_code tmp_scan

  echo ""
  echo "Post-upgrade validation..."

  [[ -f "$controlcenter_index" ]] || {
    validation_fail "missing ControlCenter entrypoint: $controlcenter_index"
    return 1
  }

  if ! command -v namei >/dev/null 2>&1; then
    validation_fail "namei is required for path permission validation"
    return 1
  fi
  echo "  namei -l $controlcenter_index"
  namei -l "$controlcenter_index" || {
    validation_fail "namei could not read $controlcenter_index"
    return 1
  }

  echo ""
  if selinux_management_enabled; then
    echo "  ls -ldZ $version_dir $controlcenter_index"
    ls -ldZ "$version_dir" "$controlcenter_index" || {
      validation_fail "ls -ldZ failed"
      return 1
    }
  else
    echo "  ls -ld $version_dir $controlcenter_index"
    ls -ld "$version_dir" "$controlcenter_index" || {
      validation_fail "ls -ld failed"
      return 1
    }
  fi

  if selinux_management_enabled && selinux_active; then
    version_type="$(selinux_type "$version_dir" || true)"
    index_type="$(selinux_type "$controlcenter_index" || true)"
    [[ "$version_type" == "httpd_sys_content_t" ]] || {
      validation_fail "$version_dir has SELinux type '${version_type:-unknown}', expected httpd_sys_content_t"
      return 1
    }
    [[ "$index_type" == "httpd_sys_content_t" ]] || {
      validation_fail "$controlcenter_index has SELinux type '${index_type:-unknown}', expected httpd_sys_content_t"
      return 1
    }

    tmp_scan="$(mktemp)"
    _TMPFILES+=("$tmp_scan")
    if find "$version_dir" -context '*:user_tmp_t:*' -print -quit >"$tmp_scan" 2>/dev/null; then
      if [[ -s "$tmp_scan" ]]; then
        local bad_path
        bad_path="$(head -n 1 "$tmp_scan")"
        validation_fail "user_tmp_t remains under new version: $bad_path"
        return 1
      fi
    else
      validation_fail "could not scan for user_tmp_t labels under $version_dir"
      return 1
    fi
    while IFS= read -r writable_path; do
      writable_type="$(selinux_type "$writable_path" || true)"
      [[ "$writable_type" == "httpd_sys_rw_content_t" ]] || {
        validation_fail "$writable_path has SELinux type '${writable_type:-unknown}', expected httpd_sys_rw_content_t"
        return 1
      }
    done < <(existing_writable_paths)
    echo "  SELinux labels OK: httpd_sys_content_t, writable paths httpd_sys_rw_content_t, no user_tmp_t under new version."
  elif ! selinux_management_enabled; then
    echo "  SELinux management disabled; skipped SELinux type and user_tmp_t assertions."
  else
    echo "  SELinux inactive or unavailable; skipped SELinux type assertions."
  fi

  if ! command -v curl >/dev/null 2>&1; then
    validation_fail "curl is required for HTTP smoke validation"
    return 1
  fi
  smoke_base="$(infer_http_base_url)" || {
    validation_fail "could not infer HTTP base URL from REDCAP_ROOT=$REDCAP_ROOT"
    return 1
  }
  smoke_url="${smoke_base}/redcap_v${TARGET_VERSION}/ControlCenter/index.php"

  echo "  HTTP smoke: $smoke_url"
  http_code="$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 --noproxy '*' "$smoke_url" || true)"
  case "$http_code" in
    2*|3*)
      echo "  HTTP smoke OK: $http_code"
      ;;
    *)
      validation_fail "HTTP smoke check returned '${http_code:-curl failed}' for $smoke_url"
      return 1
      ;;
  esac

  echo "Post-upgrade validation passed."
}

# ── Step 1: Get current version ────────────────────────────────────────────────
echo "Determining current REDCap version from database..."
CURRENT_VERSION="$(get_current_version)"
echo "  Current version: $CURRENT_VERSION"
echo ""

# ── Step 2: Fetch available versions ──────────────────────────────────────────
echo "Fetching available versions from VUMC endpoint..."
VERSIONS_JSON="$(mktemp)"
_TMPFILES+=("$VERSIONS_JSON")

if ! fetch_versions_json "$CURRENT_VERSION" > "$VERSIONS_JSON" 2>/dev/null || [[ ! -s "$VERSIONS_JSON" ]]; then
  echo "ERROR: Could not fetch versions from $VERSIONS_URL" >&2
  echo "  Check network connectivity or try --skip-download with a specific TARGET_VERSION." >&2
  exit 1
fi

CURRENT_BRANCH="$(get_current_branch "$VERSIONS_JSON" 2>/dev/null || true)"

# ── --check-versions: display and exit ────────────────────────────────────────
if $CHECK_VERSIONS; then
  echo "Versions available (newer than $CURRENT_VERSION):"
  echo ""
  print_versions "$VERSIONS_JSON"
  exit 0
fi

# ── Step 3: Select target version ─────────────────────────────────────────────
if [[ -z "$TARGET_VERSION" ]]; then
  # AVAILABLE_VERSIONS holds version numbers; AVAILABLE_BRANCHES holds matching branch
  AVAILABLE_VERSIONS=()
  AVAILABLE_BRANCHES=()
  while IFS=$'\t' read -r ver branch; do
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    AVAILABLE_VERSIONS+=("$ver")
    AVAILABLE_BRANCHES+=("$branch")
  done < <(get_version_list "$VERSIONS_JSON" 2>/dev/null || true)

  if [[ ${#AVAILABLE_VERSIONS[@]} -eq 0 ]]; then
    echo "No newer versions are available from the endpoint for version $CURRENT_VERSION." >&2
    echo "If you want to re-run a version already installed, pass TARGET_VERSION explicitly." >&2
    exit 1
  fi

  echo "Versions available to upgrade to (newer than $CURRENT_VERSION):"
  echo ""
  for i in "${!AVAILABLE_VERSIONS[@]}"; do
    v="${AVAILABLE_VERSIONS[i]}"
    branch="${AVAILABLE_BRANCHES[i]}"
    tag=""
    [[ "$branch" == "lts" ]] && tag=" [LTS]"
    local_note=""
    [[ -d "$REDCAP_ROOT/redcap_v$v" ]] && local_note="  [already on disk]"
    printf "  %2d) %s%s%s\n" "$((i+1))" "$v" "$tag" "$local_note"
  done
  echo "   q) Quit"
  echo ""

  while true; do
    read -r -p "Choice [1-${#AVAILABLE_VERSIONS[@]} or version number]: " choice
    [[ -z "$choice" ]] && continue
    [[ "$choice" == "q" || "$choice" == "Q" ]] && exit 0
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#AVAILABLE_VERSIONS[@]} )); then
      TARGET_VERSION="${AVAILABLE_VERSIONS[choice-1]}"
      break
    fi
    if [[ "$choice" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      for v in "${AVAILABLE_VERSIONS[@]}"; do
        if [[ "$v" == "$choice" ]]; then
          TARGET_VERSION="$choice"
          break 2
        fi
      done
      echo "  $choice is not in the list above." >&2
    else
      echo "  Invalid choice." >&2
    fi
  done
  echo ""
fi

VERSION_DIR="$REDCAP_ROOT/redcap_v$TARGET_VERSION"

# ── LTS → non-LTS branch switch warning ───────────────────────────────────────
# If the current running version is on LTS, look up what branch the chosen
# target is on and warn before proceeding.
if [[ "$CURRENT_BRANCH" == "lts" ]]; then
  TARGET_BRANCH="$(python3 - "$VERSIONS_JSON" "$TARGET_VERSION" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
target = sys.argv[2]
for branch in ("lts", "std"):
    for v in d.get(branch, []):
        if v.get("version_number") == target:
            print(branch)
            sys.exit(0)
# Not in the endpoint list — can't determine; print nothing
PY
2>/dev/null || true)"

  if [[ "$TARGET_BRANCH" == "std" ]]; then
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │  WARNING: LTS → Standard branch switch                          │"
    echo "  │                                                                 │"
    echo "  │  Your current install ($CURRENT_VERSION) is on the LTS branch.  │"
    echo "  │  REDCap $TARGET_VERSION is a Standard release.                  │"
    echo "  │                                                                 │"
    echo "  │  LTS receives only critical fixes; Standard receives all new    │"
    echo "  │  features but has shorter support windows. Once you switch to   │"
    echo "  │  Standard you cannot go back to LTS without a fresh install.   │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""
    read -r -p "  Type YES to confirm switching from LTS to Standard: " confirm
    echo ""
    if [[ "$confirm" != "YES" ]]; then
      echo "Aborted. No changes were made."
      exit 0
    fi
  fi
fi

# ── Step 4: Download and extract version zip ───────────────────────────────────
NEED_DOWNLOAD=false
if [[ ! -d "$VERSION_DIR" ]]; then
  NEED_DOWNLOAD=true
elif $SKIP_DOWNLOAD; then
  echo "Skipping download: $VERSION_DIR already on disk (--skip-download)."
else
  echo "Version directory already exists: $VERSION_DIR"
  read -r -p "Re-download and overwrite? [y/N]: " yn
  echo ""
  [[ "$yn" =~ ^[Yy]$ ]] && NEED_DOWNLOAD=true
fi

if $NEED_DOWNLOAD; then
  COMM_USER="${REDCAP_COMMUNITY_USER:-}"
  COMM_PASS="${REDCAP_COMMUNITY_PASSWORD:-}"

  ZIP_FILE="$(mktemp --suffix=.zip)"
  _TMPFILES+=("$ZIP_FILE")

  # Retry loop — re-prompt on credential errors
  while true; do
    if [[ -z "$COMM_USER" ]]; then
      read -r -p "VUMC Community username: " COMM_USER
    fi
    if [[ -z "$COMM_PASS" ]]; then
      read -r -s -p "VUMC Community password: " COMM_PASS
      echo ""
    fi
    echo ""
    echo "Downloading REDCap v$TARGET_VERSION from VUMC..."

    if ! download_version_zip "$TARGET_VERSION" "$COMM_USER" "$COMM_PASS" "$ZIP_FILE"; then
      echo "ERROR: Download request failed (network error)." >&2
      exit 1
    fi

    if [[ ! -s "$ZIP_FILE" ]]; then
      echo "ERROR: Downloaded file is empty." >&2
      exit 1
    fi

    # The endpoint returns JSON {"ERROR":"..."} when credentials are wrong
    FIRST_CHAR="$(head -c1 "$ZIP_FILE")"
    if [[ "$FIRST_CHAR" == "{" ]]; then
      ERR="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('ERROR', 'Unknown error'))
except Exception:
    print(open(sys.argv[1]).read()[:200])
" "$ZIP_FILE" 2>/dev/null || true)"
      echo "ERROR: VUMC responded: $ERR" >&2
      echo ""
      read -r -p "Retry with different credentials? [y/N]: " retry
      echo ""
      if [[ ! "$retry" =~ ^[Yy]$ ]]; then
        exit 1
      fi
      # Clear credentials so they are prompted again on next iteration
      COMM_USER=""
      COMM_PASS=""
      continue
    fi

    break  # Successful download
  done

  if ! command -v unzip >/dev/null 2>&1; then
    echo "ERROR: 'unzip' is required to extract the zip. Install it and retry." >&2
    exit 1
  fi

  TMP_EXTRACT="$(mktemp -d)"
  _TMPFILES+=("$TMP_EXTRACT")

  echo "Extracting zip..."
  if ! unzip -q "$ZIP_FILE" -d "$TMP_EXTRACT"; then
    echo "ERROR: Failed to extract the downloaded zip." >&2
    exit 1
  fi

  # Zip structure from VUMC: redcap/redcap_vX.Y.Z/
  SRC_DIR="$TMP_EXTRACT/redcap/redcap_v$TARGET_VERSION"
  if [[ ! -d "$SRC_DIR" ]]; then
    echo "ERROR: Expected directory not found in zip: redcap/redcap_v$TARGET_VERSION/" >&2
    echo "  Zip contents (top level):" >&2
    ls "$TMP_EXTRACT/" >&2 || true
    exit 1
  fi

  install_version_tree "$SRC_DIR" "$VERSION_DIR"
  echo ""
fi

sync_version_owner_group "$VERSION_DIR"
apply_selinux_labels "$VERSION_DIR"

# ── Step 5: Validate upgrade.php exists ───────────────────────────────────────
UPGRADE_PHP="$VERSION_DIR/upgrade.php"
if [[ ! -f "$UPGRADE_PHP" ]]; then
  echo "ERROR: Upgrade script not found: $UPGRADE_PHP" >&2
  exit 1
fi

# ── Step 6: Generate upgrade SQL via PHP (same method as upgrade.php web page) ─
echo "REDCap Easy Upgrade"
echo "  REDCAP_ROOT:    $REDCAP_ROOT"
echo "  Current:        $CURRENT_VERSION"
echo "  Target:         $TARGET_VERSION"
echo "  Run as user:    $RUN_USER"
echo "  Dry-run:        $DRY_RUN"
echo ""

SQL_FILE="$(mktemp --suffix=.sql)"
_TMPFILES+=("$SQL_FILE")

echo "Generating upgrade SQL..."
(cd "$VERSION_DIR" && php -d display_errors=0 -r '
  $_GET["download_file"] = "1";
  $_SERVER["PHP_SELF"] = "/redcap/redcap_v'"$TARGET_VERSION"'/upgrade.php";
  $_SERVER["SCRIPT_NAME"] = $_SERVER["PHP_SELF"];
  $_SERVER["REQUEST_URI"] = $_SERVER["PHP_SELF"] . "?download_file=1";
  require "upgrade.php";
' 2>/dev/null) > "$SQL_FILE"

if [[ ! -s "$SQL_FILE" ]]; then
  echo "ERROR: No SQL generated." >&2
  echo "  Possible causes: database is already at $TARGET_VERSION, or PHP/database config issue." >&2
  exit 1
fi

if $DRY_RUN; then
  echo "--- Upgrade SQL (dry-run; not executed) ---"
  cat "$SQL_FILE"
  echo "--- end SQL ---"
  exit 0
fi

# ── Step 7: Resolve MySQL credentials and execute upgrade SQL ─────────────────
# Priority: explicit env vars > redcap_config (redcap_updates_user) > database.php main user
AUTO_MYSQL_HOST="" AUTO_MYSQL_PORT="" AUTO_MYSQL_DB="" AUTO_MYSQL_USER="" AUTO_MYSQL_PASS=""
AUTO_MYSQL_SSL_CA="" AUTO_MYSQL_SSL_CERT="" AUTO_MYSQL_SSL_KEY=""

if command -v php >/dev/null 2>&1; then
  eval "$(get_db_credentials "$REDCAP_ROOT" 2>/dev/null || true)"
fi

# Resolve each value: top-of-script var > auto-detected from database.php > error/prompt
# Host, port, db have no hardcoded fallback — they must come from database.php or be set explicitly.
MYSQL_HOST="${REDCAP_UPGRADE_MYSQL_HOST:-${AUTO_MYSQL_HOST:-}}"
MYSQL_PORT="${REDCAP_UPGRADE_MYSQL_PORT:-${AUTO_MYSQL_PORT:-}}"
MYSQL_DB="${REDCAP_UPGRADE_MYSQL_DB:-${AUTO_MYSQL_DB:-}}"
MYSQL_USER="${REDCAP_UPGRADE_MYSQL_USER:-${AUTO_MYSQL_USER:-}}"
MYSQL_PASS="${REDCAP_UPGRADE_MYSQL_PASSWORD:-${AUTO_MYSQL_PASS:-}}"
MYSQL_SSL_CA="${REDCAP_UPGRADE_MYSQL_SSL_CA:-${AUTO_MYSQL_SSL_CA:-}}"
MYSQL_SSL_CERT="${REDCAP_UPGRADE_MYSQL_SSL_CERT:-${AUTO_MYSQL_SSL_CERT:-}}"
MYSQL_SSL_KEY="${REDCAP_UPGRADE_MYSQL_SSL_KEY:-${AUTO_MYSQL_SSL_KEY:-}}"

if [[ -z "$MYSQL_HOST" ]] || [[ -z "$MYSQL_PORT" ]] || [[ -z "$MYSQL_DB" ]]; then
  echo "ERROR: Could not determine MySQL host/port/db from database.php." >&2
  echo "  Set REDCAP_UPGRADE_MYSQL_HOST, REDCAP_UPGRADE_MYSQL_PORT, and REDCAP_UPGRADE_MYSQL_DB at the top of this script." >&2
  exit 1
fi

if [[ -z "$MYSQL_USER" ]]; then
  read -r -p "MySQL username for upgrade: " MYSQL_USER
fi
if [[ -z "$MYSQL_PASS" ]]; then
  read -r -s -p "MySQL password for '$MYSQL_USER': " MYSQL_PASS
  echo ""
fi
if [[ -z "$MYSQL_USER" ]] || [[ -z "$MYSQL_PASS" ]]; then
  echo "ERROR: MySQL credentials are required to run the upgrade." >&2
  echo "  Use --dry-run to only generate the SQL without executing." >&2
  exit 1
fi

echo "  MySQL host:     $MYSQL_HOST:$MYSQL_PORT"
echo "  MySQL db:       $MYSQL_DB"
echo "  MySQL user:     $MYSQL_USER"
echo ""

MYSQL_OPTS=(-h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB")
[[ -n "$MYSQL_SSL_CA"   && -f "$MYSQL_SSL_CA"   ]] && MYSQL_OPTS+=(--ssl-ca="$MYSQL_SSL_CA")
[[ -n "$MYSQL_SSL_CERT" && -f "$MYSQL_SSL_CERT" ]] && MYSQL_OPTS+=(--ssl-cert="$MYSQL_SSL_CERT")
[[ -n "$MYSQL_SSL_KEY"  && -f "$MYSQL_SSL_KEY"  ]] && MYSQL_OPTS+=(--ssl-key="$MYSQL_SSL_KEY")

echo "Executing upgrade SQL..."
if mysql "${MYSQL_OPTS[@]}" < "$SQL_FILE"; then
  echo ""
  echo "Upgrade to REDCap v$TARGET_VERSION completed successfully."
else
  echo "ERROR: mysql exited with an error." >&2
  exit 1
fi

validate_post_upgrade "$VERSION_DIR"

# ── Post-upgrade: check web server write permissions ──────────────────────────
# The web server should never have write access to REDCAP_ROOT (except temp/).
# If it does, REDCap files could be tampered with via an exploited vulnerability.
check_webserver_permissions() {
  # Find the first known web server account that actually exists on this system
  local web_user=""
  for u in $FORBIDDEN_USERS; do
    if id "$u" >/dev/null 2>&1; then
      web_user="$u"
      break
    fi
  done
  [[ -z "$web_user" ]] && return 0

  # Analyse ownership and permissions of REDCAP_ROOT
  local dir_owner dir_group dir_mode owner_w=0 group_w=0 other_w=0
  local web_in_group=false has_write=false
  dir_owner="$(stat -c '%U' "$REDCAP_ROOT" 2>/dev/null || true)"
  dir_group="$(stat -c '%G' "$REDCAP_ROOT" 2>/dev/null || true)"
  dir_mode="$(stat -c '%a'  "$REDCAP_ROOT" 2>/dev/null || true)"
  [[ -z "$dir_mode" ]] && return 0

  owner_w=$(( (8#$dir_mode >> 6) & 2 ))
  group_w=$(( (8#$dir_mode >> 3) & 2 ))
  other_w=$(( 8#$dir_mode        & 2 ))

  id -Gn "$web_user" 2>/dev/null | tr ' ' '\n' | grep -qx "$dir_group" && web_in_group=true

  [[ "$dir_owner" == "$web_user" && $owner_w -ne 0 ]] && has_write=true
  $web_in_group && [[ $group_w -ne 0 ]] && has_write=true
  [[ $other_w -ne 0 ]] && has_write=true

  $has_write || return 0

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════════╗"
  echo "║                                                                          ║"
  echo "║   !!!  DANGER: WEB SERVER HAS WRITE ACCESS TO REDCAP ROOT  !!!          ║"
  echo "║                                                                          ║"
  echo "║   Web server user : $web_user"
  echo "║   Directory       : $REDCAP_ROOT"
  echo "║   Owner/Group     : $dir_owner / $dir_group  (mode $dir_mode)"
  echo "║                                                                          ║"
  echo "║   The web server ($web_user) can WRITE to the REDCap directory.         ║"
  echo "║   If an attacker exploits a vulnerability in REDCap or PHP, they        ║"
  echo "║   could modify REDCap source files, inject backdoors, or steal data.    ║"
  echo "║                                                                          ║"
  echo "║   RECOMMENDED: The web server should only READ REDCap files.            ║"
  echo "║   Only temp/ needs to be writable by the web server.                    ║"
  echo "║                                                                          ║"
  echo "╚══════════════════════════════════════════════════════════════════════════╝"
  echo ""
  read -r -p "Fix permissions now? (root owns all; $web_user writable only for temp/) [y/N]: " fix_perms
  echo ""

  if [[ "$fix_perms" =~ ^[Yy]$ ]]; then
    echo "Fixing permissions... (this may take a moment)"

    echo "  [$(date +%H:%M:%S)] 1/4: Resetting ownership of all files to root:root..."
    chown -R root:root "$REDCAP_ROOT" 2>/dev/null || true

    echo "  [$(date +%H:%M:%S)] 2/4: Setting directory (755) and file (644) modes..."
    chmod -R u+rwX,go+rX,go-w "$REDCAP_ROOT" 2>/dev/null || true

    # Restore temp/ so the web server can write to it
    if [[ -d "$REDCAP_ROOT/temp" ]]; then
      echo "  [$(date +%H:%M:%S)] 3/4: Restoring web server ownership for temp/ directory..."
      chown -R "$web_user:$web_user" "$REDCAP_ROOT/temp" 2>/dev/null || true
      echo "  [$(date +%H:%M:%S)] 4/4: Setting web server write permissions for temp/ directory..."
      chmod -R u+rwX,go-rwx "$REDCAP_ROOT/temp" 2>/dev/null || true
      echo "  [$(date +%H:%M:%S)] Done."
      echo ""
      echo "  $REDCAP_ROOT         → root:root, dirs=755, files=644"
      echo "  $REDCAP_ROOT/temp/   → $web_user:$web_user, 700 (web server only)"
    else
      echo "  [$(date +%H:%M:%S)] Done."
      echo ""
      echo "  $REDCAP_ROOT → root:root, dirs=755, files=644"
    fi
    echo ""
    echo "Permissions fixed. Verify with: ls -la $REDCAP_ROOT"
  else
    echo "Permissions NOT changed. Address this before putting the server into production."
  fi
}

check_webserver_permissions

# ── Post-upgrade: offer to delete old redcap_v* directories ───────────────────
# Reads the deletion conditions directly from the newly installed check.php so
# the logic is always correct regardless of which version was just installed.
#
# check.php flags versions by comparing a decimal representation of each
# installed redcap_v* directory name against a set of if/elseif conditions.
# Rather than hardcoding those thresholds here (they change every release), we:
#   1. Parse check.php with PHP to extract the exact condition expressions
#   2. Apply those conditions to every installed redcap_v* directory
#   3. Prompt the user to confirm deletion of each flagged directory
check_old_version_dirs() {
  local check_php="$REDCAP_ROOT/redcap_v$TARGET_VERSION/ControlCenter/check.php"

  if [[ ! -f "$check_php" ]]; then
    echo "  (Skipping old-version cleanup: check.php not found at $check_php)"
    return 0
  fi

  if ! command -v php >/dev/null 2>/dev/null; then
    echo "  (Skipping old-version cleanup: php CLI not available)"
    return 0
  fi

  # PHP reads check.php, extracts the if/elseif conditions that push to
  # $deleteRedcapDirs, and applies them to each installed redcap_v* directory.
  # Outputs one version number per line for each directory that should be deleted.
  mapfile -t flagged < <(
    PHPRC_ROOT="$REDCAP_ROOT" PHPRC_TARGET="$TARGET_VERSION" \
    php -d display_errors=0 2>/dev/null <<'PHPEOF'
<?php
$root   = getenv('PHPRC_ROOT');
$target = getenv('PHPRC_TARGET');
$check  = $root . '/redcap_v' . $target . '/ControlCenter/check.php';

if (!is_readable($check)) exit;

// Mirrors Upgrade::getDecVersion(): "15.5.35" -> 150535
function decVer(string $v): int {
    [$one, $two, $three] = explode('.', $v) + [0, 0, 0];
    return (int)($one . sprintf('%02d', (int)$two) . sprintf('%02d', (int)$three));
}

// Extract conditions from check.php that add entries to $deleteRedcapDirs.
// Each condition is on a single if/elseif line immediately before a line
// that contains "$deleteRedcapDirs[" — scan for that pattern.
$lines      = file($check, FILE_IGNORE_NEW_LINES);
$conditions = [];
$n          = count($lines);
for ($i = 0; $i < $n; $i++) {
    $trimmed = trim($lines[$i]);
    // Match:  if (EXPR) {   or   } elseif (EXPR) {
    if (!preg_match('/^(?:(?:\}\s*)?elseif|if)\s*\((.+)\)\s*\{?\s*$/', $trimmed, $m)) continue;
    // Peek at the next non-empty line — it must add to $deleteRedcapDirs
    for ($j = $i + 1; $j < $n && trim($lines[$j]) === ''; $j++);
    if (isset($lines[$j]) && strpos($lines[$j], '$deleteRedcapDirs[') !== false) {
        $raw = trim($m[1]);
        // Sanity check: only allow safe tokens before eval-ing
        if (preg_match('/^[\s\$versionDec0-9<>&|!()\*]+$/', $raw)) {
            $conditions[] = $raw;
        }
    }
}

if (empty($conditions)) exit;

$target_dec = decVer($target);
$dirs       = glob($root . '/redcap_v*', GLOB_ONLYDIR) ?: [];

foreach ($dirs as $dir) {
    $ver = substr(basename($dir), strlen('redcap_v'));
    if (!preg_match('/^\d+\.\d+\.\d+$/', $ver)) continue;
    $versionDec = decVer($ver);          // matches the variable name in check.php
    if ($versionDec === $target_dec) continue;  // never flag the version we just installed

    // Apply extracted conditions, preserving the if/elseif chain:
    // once a condition matches, skip the rest (matches check.php semantics)
    foreach ($conditions as $cond) {
        $expr = str_replace('$versionDec', (string)$versionDec, $cond);
        if (eval("return (bool)($expr);")) {
            echo $ver . "\n";
            break;
        }
    }
}
PHPEOF
  )

  if [[ ${#flagged[@]} -eq 0 ]]; then
    echo "  No old version directories flagged for deletion by check.php."
    return 0
  fi

  # Sort oldest first
  mapfile -t flagged < <(printf '%s\n' "${flagged[@]}" | sort -V)

  echo ""
  echo "─────────────────────────────────────────────────────────────────────────────"
  echo "  Old REDCap version directories flagged for deletion"
  echo "  (conditions read from redcap_v${TARGET_VERSION}/ControlCenter/check.php)"
  echo "─────────────────────────────────────────────────────────────────────────────"
  echo ""

  for ver in "${flagged[@]}"; do
    local dir="$REDCAP_ROOT/redcap_v$ver"
    read -r -p "  Delete $dir ? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      rm -rf "$dir"
      echo "  Deleted: $dir"
    else
      echo "  Kept:    $dir"
    fi
    echo ""
  done
}

check_old_version_dirs
