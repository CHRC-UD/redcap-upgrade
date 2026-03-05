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
#   7. Checks Unix permissions and SELinux contexts for security issues
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
# Edit this section to match your environment.
# Every value can also be supplied as an environment variable at runtime,
# which takes precedence over what is set here.
# Leave a value empty ("") to fall back to auto-detection or interactive prompt.
# =============================================================================

# Full path to the REDCap webroot — the directory that contains database.php
# and all redcap_v* version folders.
REDCAP_ROOT="${REDCAP_ROOT:-/var/www/html/redcap}"

# ---------------------------------------------------------------------------
# VUMC Community credentials
# Used to authenticate the upgrade zip download from the VUMC endpoint.
# If left blank, the script will prompt interactively and retry on failure.
# ---------------------------------------------------------------------------
REDCAP_COMMUNITY_USER="${REDCAP_COMMUNITY_USER:-}"
REDCAP_COMMUNITY_PASSWORD="${REDCAP_COMMUNITY_PASSWORD:-}"

# ---------------------------------------------------------------------------
# MySQL connection — upgrade SQL execution
# The script reads these automatically from database.php (host/port/db) and
# redcap_config (user/pass via redcap_updates_user). Only override here if
# auto-detection fails or you need a different user for the upgrade.
# If user/pass remain empty after auto-detection, the script will prompt.
# ---------------------------------------------------------------------------
REDCAP_UPGRADE_MYSQL_USER="${REDCAP_UPGRADE_MYSQL_USER:-}"
REDCAP_UPGRADE_MYSQL_PASSWORD="${REDCAP_UPGRADE_MYSQL_PASSWORD:-}"

# Leave blank to auto-detect from database.php (strongly recommended).
REDCAP_UPGRADE_MYSQL_HOST="${REDCAP_UPGRADE_MYSQL_HOST:-}"
REDCAP_UPGRADE_MYSQL_PORT="${REDCAP_UPGRADE_MYSQL_PORT:-}"
REDCAP_UPGRADE_MYSQL_DB="${REDCAP_UPGRADE_MYSQL_DB:-}"

# SSL certificate paths for MySQL. Leave blank to auto-detect from database.php.
REDCAP_UPGRADE_MYSQL_SSL_CA="${REDCAP_UPGRADE_MYSQL_SSL_CA:-}"
REDCAP_UPGRADE_MYSQL_SSL_CERT="${REDCAP_UPGRADE_MYSQL_SSL_CERT:-}"
REDCAP_UPGRADE_MYSQL_SSL_KEY="${REDCAP_UPGRADE_MYSQL_SSL_KEY:-}"

# ---------------------------------------------------------------------------
# Safety — accounts that must NOT run this script (web server service accounts).
# Add your site's service account names here if they differ from the defaults.
# ---------------------------------------------------------------------------
REDCAP_UPGRADE_FORBIDDEN_USERS="${REDCAP_UPGRADE_FORBIDDEN_USERS:-apache www-data wwwrun nginx}"

# =============================================================================
# END OF CONFIGURATION
# Do not edit below this line unless you know what you are doing.
# =============================================================================

set -euo pipefail

VERSIONS_URL="https://redcap.vumc.org/plugins/redcap_consortium/versions.php"
FORBIDDEN_USERS="$REDCAP_UPGRADE_FORBIDDEN_USERS"
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
fetch_versions_json() {
  local current="$1"
  curl -fsS --connect-timeout 20 "${VERSIONS_URL}?current_version=${current}" 2>/dev/null
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
  curl -sS --connect-timeout 60 --max-time 300 \
    --data-urlencode "username=$comm_user" \
    --data-urlencode "password=$comm_pass" \
    --data-urlencode "version=$version" \
    -o "$zip_file" \
    "$VERSIONS_URL"
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

  if [[ -d "$VERSION_DIR" ]]; then
    echo "Removing existing $VERSION_DIR ..."
    rm -rf "$VERSION_DIR"
  fi

  mv "$SRC_DIR" "$VERSION_DIR"
  echo "Installed: $VERSION_DIR"
  echo ""
fi

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
    echo "Fixing permissions..."

    # Transfer ownership of everything to root (safe admin baseline)
    chown -R root:root "$REDCAP_ROOT" 2>/dev/null || true

    # Dirs readable+executable by all, files readable by all — no write for group/other
    chmod -R u+rwX,go+rX,go-w "$REDCAP_ROOT" 2>/dev/null || true

    # Restore temp/ so the web server can write to it
    if [[ -d "$REDCAP_ROOT/temp" ]]; then
      chown -R "$web_user:$web_user" "$REDCAP_ROOT/temp" 2>/dev/null || true
      chmod -R u+rwX,go-rwx "$REDCAP_ROOT/temp" 2>/dev/null || true
      echo "  $REDCAP_ROOT         → root:root, dirs=755, files=644"
      echo "  $REDCAP_ROOT/temp/   → $web_user:$web_user, 700 (web server only)"
    else
      echo "  $REDCAP_ROOT → root:root, dirs=755, files=644"
    fi
    echo ""
    echo "Permissions fixed. Verify with: ls -la $REDCAP_ROOT"
  else
    echo "Permissions NOT changed. Address this before putting the server into production."
  fi
}

check_webserver_permissions

# ── Post-upgrade: check SELinux contexts ──────────────────────────────────────
# If SELinux is Enforcing or Permissive (audit), the httpd context on REDCAP_ROOT
# should be httpd_sys_content_t (read-only). If it is a writable type, or the
# httpd_unified boolean is on, Apache can write to the webroot.
check_selinux_permissions() {
  command -v getenforce >/dev/null 2>&1 || return 0
  local selinux_mode
  selinux_mode="$(getenforce 2>/dev/null || true)"
  [[ "$selinux_mode" == "Enforcing" || "$selinux_mode" == "Permissive" ]] || return 0

  # Get the SELinux type label on REDCAP_ROOT (format: user:role:type:level)
  local context selinux_type
  context="$(stat -c '%C' "$REDCAP_ROOT" 2>/dev/null || true)"
  [[ -z "$context" ]] && return 0
  selinux_type="$(echo "$context" | cut -d: -f3)"

  # Types that grant httpd write access to the directory
  local has_write_type=false
  case "$selinux_type" in
    httpd_sys_rw_content_t|httpd_sys_ra_content_t|public_content_rw_t|\
    httpd_user_rw_content_t|httpd_sys_script_rw_t|var_t|tmp_t|unlabeled_t)
      has_write_type=true ;;
  esac

  # httpd_unified ON means httpd treats all httpd_* types as fully accessible
  local httpd_unified=false
  if command -v getsebool >/dev/null 2>/dev/null; then
    getsebool httpd_unified 2>/dev/null | grep -q '--> on$' && httpd_unified=true
  fi

  $has_write_type || $httpd_unified || {
    echo "  SELinux ($selinux_mode): context OK ($selinux_type)"
    return 0
  }

  local reason=""
  $has_write_type  && reason="context type '$selinux_type' grants httpd write access"
  $httpd_unified   && reason="${reason:+$reason; }boolean 'httpd_unified' is ON"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════════╗"
  echo "║                                                                          ║"
  echo "║   !!!  DANGER: SELinux ALLOWS HTTPD WRITE ACCESS TO REDCAP ROOT  !!!    ║"
  echo "║                                                                          ║"
  printf "║   SELinux mode  : %-54s ║\n" "$selinux_mode"
  printf "║   Directory     : %-54s ║\n" "$REDCAP_ROOT"
  printf "║   Context type  : %-54s ║\n" "$selinux_type"
  printf "║   Reason        : %-54s ║\n" "$reason"
  echo "║                                                                          ║"
  echo "║   Apache (httpd) can WRITE to the REDCap webroot via SELinux policy.    ║"
  echo "║   A vulnerability in REDCap or PHP could allow file modification or     ║"
  echo "║   backdoor injection even if Unix permissions are correct.              ║"
  echo "║                                                                          ║"
  echo "║   Correct contexts:                                                      ║"
  echo "║     REDCAP_ROOT   → httpd_sys_content_t     (read-only for httpd)       ║"
  echo "║     temp/         → httpd_sys_rw_content_t  (writable for httpd)        ║"
  echo "║                                                                          ║"
  echo "╚══════════════════════════════════════════════════════════════════════════╝"
  echo ""

  read -r -p "Fix SELinux contexts now? [y/N]: " fix_sel
  echo ""
  [[ "$fix_sel" =~ ^[Yy]$ ]] || { echo "SELinux contexts NOT changed."; return 0; }

  if ! command -v chcon >/dev/null 2>&1; then
    echo "ERROR: chcon not found — cannot set SELinux contexts." >&2
    return 1
  fi

  echo "Setting SELinux contexts..."

  # Turn off httpd_unified if it was the problem
  if $httpd_unified && command -v setsebool >/dev/null 2>&1; then
    setsebool -P httpd_unified off 2>/dev/null && \
      echo "  httpd_unified → off (persistent)" || \
      echo "  WARNING: Could not disable httpd_unified boolean." >&2
  fi

  # Apply contexts immediately with chcon
  chcon -R -t httpd_sys_content_t    "$REDCAP_ROOT"       2>/dev/null || true
  if [[ -d "$REDCAP_ROOT/temp" ]]; then
    chcon -R -t httpd_sys_rw_content_t "$REDCAP_ROOT/temp" 2>/dev/null || true
  fi

  # Make contexts survive a relabel (restorecon) via semanage fcontext
  if command -v semanage >/dev/null 2>&1; then
    # Add/update the root rule (most specific last wins on overlap)
    semanage fcontext -a -t httpd_sys_content_t    "${REDCAP_ROOT}(/.*)?" 2>/dev/null || \
      semanage fcontext -m -t httpd_sys_content_t  "${REDCAP_ROOT}(/.*)?" 2>/dev/null || true
    if [[ -d "$REDCAP_ROOT/temp" ]]; then
      # More-specific temp rule overrides the root rule
      semanage fcontext -a -t httpd_sys_rw_content_t    "${REDCAP_ROOT}/temp(/.*)?" 2>/dev/null || \
        semanage fcontext -m -t httpd_sys_rw_content_t  "${REDCAP_ROOT}/temp(/.*)?" 2>/dev/null || true
    fi
    echo "  Contexts made persistent via semanage fcontext."
  else
    echo "  WARNING: semanage not found — chcon changes won't survive restorecon/relabel."
    echo "  Install policycoreutils-python-utils to make contexts permanent."
  fi

  echo "  $REDCAP_ROOT        → httpd_sys_content_t    (read-only for httpd)"
  [[ -d "$REDCAP_ROOT/temp" ]] && \
    echo "  $REDCAP_ROOT/temp/  → httpd_sys_rw_content_t (writable for httpd)"
  echo ""
  echo "SELinux contexts updated. Verify with: ls -Z $REDCAP_ROOT"
}

check_selinux_permissions

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

