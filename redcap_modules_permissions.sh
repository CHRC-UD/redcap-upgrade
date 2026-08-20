#!/usr/bin/env bash
# =============================================================================
# redcap_modules_permissions.sh
# =============================================================================
# Temporarily grants the web server user write access to REDCap's modules/
# directory so that External Modules can be installed/updated via the
# Control Center web interface, then waits for you to finish and restores
# the original ownership and SELinux labels.
#
# What it does — in order:
#   1. Records the current owner/group (and SELinux type, if applicable) of
#      $REDCAP_ROOT/modules
#   2. chowns modules/ to the web server user and, if SELinux is active,
#      relabels it httpd_sys_rw_content_t
#   3. Waits for you to press Enter after installing/updating modules via
#      the web UI
#   4. Restores the original owner/group and SELinux label
#
# Requirements:
#   - bash 4+
#   - Must be run as root (or a user with permission to chown modules/)
#   - Must NOT be run as the web server user (apache, www-data, etc.)
#
# Usage:
#   sudo ./redcap_modules_permissions.sh
#
#   -h, --help   Show this help text.
#
# Configuration is read from redcap_easy_upgrade.conf (same file used by
# redcap_easy_upgrade.sh): REDCAP_ROOT, REDCAP_UPGRADE_FORBIDDEN_USERS, and
# REDCAP_UPGRADE_MANAGE_SELINUX.
# =============================================================================

# ── Resolve script directory (needed for conf file path) ──────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source site config file if present (shared with redcap_easy_upgrade.sh) ───
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

[[ -z "${REDCAP_ROOT:-}"                    ]] && REDCAP_ROOT="/var/www/html/redcap"
[[ -z "${REDCAP_UPGRADE_FORBIDDEN_USERS:-}" ]] && REDCAP_UPGRADE_FORBIDDEN_USERS="apache www-data wwwrun nginx"
[[ -z "${REDCAP_UPGRADE_MANAGE_SELINUX:-}"  ]] && REDCAP_UPGRADE_MANAGE_SELINUX="true"

set -euo pipefail

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p } }' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

FORBIDDEN_USERS="$REDCAP_UPGRADE_FORBIDDEN_USERS"

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

MODULES_DIR="$REDCAP_ROOT/modules"
if [[ ! -d "$MODULES_DIR" ]]; then
  echo "ERROR: Modules directory not found: $MODULES_DIR" >&2
  exit 1
fi

# ── Find the web server account that actually exists on this system ──────────
WEB_USER=""
for u in $FORBIDDEN_USERS; do
  if id "$u" >/dev/null 2>&1; then
    WEB_USER="$u"
    break
  fi
done
if [[ -z "$WEB_USER" ]]; then
  echo "ERROR: None of the configured web server accounts exist on this system: $FORBIDDEN_USERS" >&2
  echo "  Set REDCAP_UPGRADE_FORBIDDEN_USERS in redcap_easy_upgrade.conf to include your web server account." >&2
  exit 1
fi

# ── SELinux helpers (mirrors redcap_easy_upgrade.sh) ──────────────────────────
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

fcontext_path_regex() {
  local path="$1"
  printf '%s\n' "${path//./\\.}"
}

set_fcontext_tree_rule() {
  local type="$1" path_regex="$2"
  semanage fcontext -d "$path_regex" 2>/dev/null || true
  semanage fcontext -d "${path_regex}(/.*)?" 2>/dev/null || true
  semanage fcontext -a -t "$type" "$path_regex" 2>/dev/null || \
    semanage fcontext -m -t "$type" "$path_regex"
  semanage fcontext -a -t "$type" "${path_regex}(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t "$type" "${path_regex}(/.*)?"
}

relabel_modules_dir() {
  local type="$1"
  local regex
  regex="$(fcontext_path_regex "$MODULES_DIR")"

  if command -v semanage >/dev/null 2>&1 && command -v restorecon >/dev/null 2>&1; then
    set_fcontext_tree_rule "$type" "$regex"
    restorecon -RF "$MODULES_DIR"
  elif command -v chcon >/dev/null 2>&1; then
    echo "  WARNING: semanage/restorecon unavailable; using chcon fallback (not persistent)."
    chcon -R -t "$type" "$MODULES_DIR"
  else
    echo "  WARNING: SELinux is active, but semanage/restorecon or chcon is not available; skipping relabel." >&2
  fi
}

# ── Record original state ──────────────────────────────────────────────────────
ORIG_OWNER_GROUP="$(stat -c '%U:%G' "$MODULES_DIR")"
ORIG_SELINUX_TYPE=""
MANAGE_SELINUX=false
if selinux_management_enabled && selinux_active; then
  MANAGE_SELINUX=true
  ORIG_SELINUX_TYPE="$(selinux_type "$MODULES_DIR" || true)"
fi

echo "REDCap Modules Permissions"
echo "  Modules dir:    $MODULES_DIR"
echo "  Web server user: $WEB_USER"
echo "  Original owner:  $ORIG_OWNER_GROUP"
if $MANAGE_SELINUX; then
  echo "  Original SELinux type: ${ORIG_SELINUX_TYPE:-unknown}"
fi
echo ""

# ── Restore original permissions/labels (also runs on Ctrl-C) ────────────────
RESTORED=false
restore_permissions() {
  $RESTORED && return 0
  RESTORED=true
  echo ""
  echo "Restoring original ownership: $ORIG_OWNER_GROUP"
  chown -R "$ORIG_OWNER_GROUP" "$MODULES_DIR"
  if $MANAGE_SELINUX && [[ -n "$ORIG_SELINUX_TYPE" ]]; then
    echo "Restoring original SELinux type: $ORIG_SELINUX_TYPE"
    relabel_modules_dir "$ORIG_SELINUX_TYPE"
  fi
  echo "Done. $MODULES_DIR is back to its original state."
}
trap restore_permissions EXIT INT TERM

# ── Grant the web server write access ─────────────────────────────────────────
echo "Granting $WEB_USER write access to $MODULES_DIR..."
chown -R "$WEB_USER:$WEB_USER" "$MODULES_DIR"
if $MANAGE_SELINUX; then
  echo "Relabeling $MODULES_DIR httpd_sys_rw_content_t..."
  relabel_modules_dir httpd_sys_rw_content_t
fi

echo ""
echo "─────────────────────────────────────────────────────────────────────────────"
echo "  You can now install/update External Modules via the Control Center"
echo "  web interface."
echo "─────────────────────────────────────────────────────────────────────────────"
echo ""
read -r -p "Press Enter once you have finished, to restore original permissions: " _

# restore_permissions runs automatically via the EXIT trap
