## REDCap Easy Upgrade CLI

A standalone command‑line helper for REDCap's **Easy Upgrade** feature.  
It mirrors what the web UI does, but lets you run the upgrade as a privileged admin user
instead of the web server account.

---

### Files

| File | Purpose |
|---|---|
| `redcap_easy_upgrade.sh` | Main upgrade script (bash) |
| `redcap_easy_upgrade.conf.example` | Configuration template — copy to `.conf` and edit |
| `redcap_easy_upgrade.conf` | Your site config (not committed — may contain credentials) |
| `logs/` | Per-run log files (not committed) |

---

### Requirements

- Bash 4+, `php` (CLI), `curl`, `python3`, `unzip`, `mysql` (CLI)
- Access to the REDCap webroot (defaults to `/var/www/html/redcap`)
- A MySQL user with **CREATE, DROP, ALTER, REFERENCES** on the REDCap database
- A REDCap Community (VUMC) account to download upgrade zips

---

### Setup

**1. Create your config file**

```bash
cp redcap_easy_upgrade.conf.example redcap_easy_upgrade.conf
chmod 600 redcap_easy_upgrade.conf   # protect credentials
```

**2. Edit `redcap_easy_upgrade.conf`**

At minimum, verify `REDCAP_ROOT` points to your webroot. Fill in your VUMC Community
credentials so the script can download upgrade zips non-interactively:

```bash
REDCAP_ROOT="/var/www/html/redcap"

REDCAP_COMMUNITY_USER="your_vumc_username"
REDCAP_COMMUNITY_PASSWORD="your_vumc_password"
```

All other values (MySQL host/db/user, SSL paths) auto-detect from `database.php` and
`redcap_config`. Only set them if auto-detection fails on your system.

> `redcap_easy_upgrade.conf` is excluded from version control via `.gitignore`.
> Never commit it — it may contain credentials.

---

### Usage

**Interactive upgrade (recommended)**

```bash
sudo ./redcap_easy_upgrade.sh
```

The script will:

1. Read your current REDCap version via `redcap_connect.php`.
2. Call the consortium endpoint to discover newer versions.
3. Let you **select a target version** from the list.
4. Download and install the new `redcap_v<VERSION>/` directory.
5. Preserve installed metadata, match owner/group to the existing working version, and relabel the new tree for SELinux.
6. Generate and execute the same upgrade SQL that `upgrade.php` would run.
7. Validate the new `ControlCenter/index.php` path, SELinux labels, absence of `user_tmp_t`, and HTTP reachability.
8. Prompt to delete old `redcap_v*` directories flagged by `check.php`.

A timestamped log of the full run is written to `logs/upgrade_YYYYMMDD_HHMMSS.log`.

**Upgrade to a specific version directly**

```bash
sudo ./redcap_easy_upgrade.sh 16.0.15
```

**Check what versions are available without upgrading**

```bash
./redcap_easy_upgrade.sh --check-versions
```

**Preview the upgrade SQL without touching the database**

```bash
./redcap_easy_upgrade.sh --dry-run 16.0.15
```

**Skip re-downloading if the version directory already exists on disk**

```bash
sudo ./redcap_easy_upgrade.sh --skip-download 16.0.15
```

**Pass credentials at runtime without editing the config**

```bash
sudo REDCAP_COMMUNITY_USER=me REDCAP_COMMUNITY_PASSWORD=s3cr3t \
     ./redcap_easy_upgrade.sh 16.0.15
```

Environment variables always take precedence over values in `redcap_easy_upgrade.conf`.

---

### SELinux and HTTP validation

The install step uses `rsync -aAX` when available, falling back to `cp -a`, so file modes,
ACLs, and xattrs from the extracted REDCap package are preserved before the script applies
site-specific owner/group and SELinux labels.

For SELinux systems, the script prefers persistent `semanage fcontext` rules followed by
`restorecon -RF` on the new `redcap_v<VERSION>/` directory. Writable REDCap paths listed
in `REDCAP_UPGRADE_WRITABLE_PATHS` are labeled `httpd_sys_rw_content_t` when they exist:

```bash
REDCAP_UPGRADE_MANAGE_SELINUX="true"
REDCAP_UPGRADE_WRITABLE_PATHS="temp edocs file_repository upload uploads cache"
```

Set `REDCAP_UPGRADE_MANAGE_SELINUX="false"` to skip all SELinux labeling and SELinux
validation. The default is `true`, including when the setting is absent from an existing
local config.

Set the HTTP base URL if localhost inference is not correct for your Apache vhost:

```bash
REDCAP_UPGRADE_HTTP_SMOKE_CHECK="true"
REDCAP_UPGRADE_HTTP_BASE_URL="https://redcap.example.edu/redcap"
```

Set `REDCAP_UPGRADE_HTTP_SMOKE_CHECK="false"` to skip the HTTP smoke check on hosts
where localhost requests are blocked or do not route to the REDCap vhost. The default
is `true`.

Example validation output:

```text
Installing with metadata-preserving copy...
  Using: rsync -aAX
Installed: /var/www/html/redcap/redcap_v17.0.1
Matching owner/group to existing REDCap version directories: 0:0
Applying SELinux labels for /var/www/html/redcap/redcap_v17.0.1 (mode: Enforcing)...
  Updating persistent SELinux rules...
  Updating writable SELinux rule: /var/www/html/redcap/temp
  Relabeling: /var/www/html/redcap/redcap_v17.0.1
  Relabeling writable path: /var/www/html/redcap/temp

Post-upgrade validation...
  namei -l /var/www/html/redcap/redcap_v17.0.1/ControlCenter/index.php
  ls -ldZ /var/www/html/redcap/redcap_v17.0.1 /var/www/html/redcap/redcap_v17.0.1/ControlCenter/index.php
  SELinux labels OK: httpd_sys_content_t, writable paths httpd_sys_rw_content_t, no user_tmp_t under new version.
  HTTP smoke: http://127.0.0.1/redcap/redcap_v17.0.1/ControlCenter/index.php
  HTTP smoke OK: 302
Post-upgrade validation passed.
```

If validation fails, the script stops before old-version cleanup and prints remediation
commands for the fcontext rule, `restorecon`, writable path labels, and HTTP base URL.

Idempotency and rollback behavior:

- Re-running against an existing version with download skipped re-applies owner/group,
  SELinux labeling and validation when `REDCAP_UPGRADE_MANAGE_SELINUX` is enabled.
- Re-downloading over an existing target preserves the previous target directory as
  `redcap_v<VERSION>.pre-upgrade.<timestamp>` before moving the staged copy into place.
- The script does not roll back database changes after upgrade SQL has executed; restore
  from your database backup if SQL succeeded but later validation exposes an environment issue.

---

### Logs

Every run writes a log to `logs/upgrade_YYYYMMDD_HHMMSS.log`. All stdout and stderr are
captured. Passwords typed at interactive prompts are **not** written to the log.

---

### Important safety notes

- **Never** run this script as the web server user (`apache`, `www-data`, `nginx`).  
  Run it as `root` or a dedicated admin account.
- Take a **database backup** before every upgrade.
- If your server uses an outbound proxy, set `REDCAP_UPGRADE_PROXY=http://proxy.example.com:3128`
  in your `.conf` file (or via the standard `https_proxy` / `HTTPS_PROXY` environment variables)
  so curl can reach `https://redcap.vumc.org`.
- On SELinux systems, install `policycoreutils-python-utils` so `semanage` is available
  and REDCap labels survive relabels. Without it, the script falls back to non-persistent
  `chcon` labels and validation will still run.
