#!/usr/bin/env bash
# Best-effort lifecycle markers only. Normal upgrade execution owns its terminal,
# process and exit status. A window includes all actors and approves no change.
AIDE_UPGRADE_ID=""
AIDE_UPGRADE_COMPLETE=false
_AIDE_UPGRADE_MANAGED=false

aide_upgrade_begin() {
  local version=${1:?version required} dry_run=${2:?dry-run flag required}
  local ledger=${REDCAP_UPGRADE_AIDE_LEDGER:-/usr/local/libexec/aide-observer/upgrade_window.py}
  [[ ${REDCAP_UPGRADE_AIDE_TRACKING:-false} == true && $dry_run == false ]] || return 0
  if ! command -v timeout >/dev/null 2>&1 || [[ ! -x $ledger ]]; then
    echo 'WARNING: AIDE upgrade tracking unavailable; changes remain unclassified.' >&2
    return 0
  fi
  local host record returned_id
  host=$(hostname -f) || { echo 'WARNING: Cannot determine upgrade host.' >&2; return 0; }
  if ! AIDE_UPGRADE_ID=$(python3 -c 'import uuid; print(uuid.uuid4())'); then
    AIDE_UPGRADE_ID=""
    echo 'WARNING: Cannot create AIDE upgrade identifier; changes remain unclassified.' >&2
    return 0
  fi
  if ! record=$(timeout --kill-after=2s 5s "$ledger" begin --id "$AIDE_UPGRADE_ID" --version "$version" --host "$host"); then
    # Keep the preselected ID: the ledger may have committed before timing out.
    # The exit hook attempts to finish that same record, without trusting it.
    echo 'WARNING: Could not confirm AIDE upgrade start; changes remain unclassified.' >&2
    return 0
  fi
  if ! returned_id=$(python3 -c 'import json,sys,uuid; v=json.load(sys.stdin)["upgrade_id"]; assert str(uuid.UUID(v))==v; print(v)' <<< "$record") || [[ $returned_id != "$AIDE_UPGRADE_ID" ]]; then
    echo 'WARNING: AIDE upgrade tracking returned an unexpected identifier; changes remain unclassified.' >&2
  fi
}

aide_upgrade_finish() {
  local exit_status=${1:?exit status required}
  [[ -n ${AIDE_UPGRADE_ID:-} ]] || return 0
  local ledger=${REDCAP_UPGRADE_AIDE_LEDGER:-/usr/local/libexec/aide-observer/upgrade_window.py}
  local status=failed
  if [[ $exit_status -ge 128 ]]; then
    status=interrupted
  elif [[ $exit_status -eq 0 && ${AIDE_UPGRADE_COMPLETE:-false} == true ]]; then
    # Script completion alone does not prove package/manifest verification.
    status=completed_unverified
  fi
  if ! timeout --kill-after=2s 5s "$ledger" finish --id "$AIDE_UPGRADE_ID" --status "$status" >/dev/null; then
    echo 'WARNING: Could not record AIDE upgrade completion; changes remain unclassified.' >&2
  fi
  AIDE_UPGRADE_ID=""
}

aide_upgrade_bootstrap() {
  if [[ -e /etc/aide-observer-upgrade.json || -L /etc/aide-observer-upgrade.json ]]; then
    local configured
    if ! configured=$(python3 - <<'AIDE_CONFIG'
import json,os,socket,stat
fd=os.open('/etc/aide-observer-upgrade.json',os.O_RDONLY|os.O_NOFOLLOW)
try:
    info=os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=0 or info.st_mode&0o022 or info.st_nlink!=1 or info.st_size>8192:
        raise SystemExit('Unsafe AIDE upgrade policy')
    data=json.loads(os.read(fd,8193))
finally:os.close(fd)
if set(data)!={'schema','enabled','host','grouping'} or type(data['schema']) is not int or data['schema']!=2 or type(data['enabled']) is not bool or data['host']!=socket.getfqdn() or data['grouping']!='temporal_window':
    raise SystemExit('Invalid AIDE upgrade-window policy')
if data['enabled'] and data['host']!='dev-web-redcap.chrc.udel.edu':raise SystemExit('Unexpected upgrade-window host')
print('true' if data['enabled'] else 'false')
AIDE_CONFIG
); then
      echo 'WARNING: Invalid AIDE window policy; tracking disabled for this upgrade.' >&2
      configured=false
    fi
    REDCAP_UPGRADE_AIDE_TRACKING=$configured
    export REDCAP_UPGRADE_AIDE_TRACKING
  fi
  return 0
}

# Compatibility with the existing entry point: never relay or relaunch it.
aide_upgrade_maybe_launch() { return 0; }

# Observation must not freeze or replace a filesystem command.
aide_upgrade_filesystem() { "$@"; }
