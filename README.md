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
5. Generate and execute the same upgrade SQL that `upgrade.php` would run.
6. Offer to tighten Unix permissions and SELinux contexts on the webroot.
7. Prompt to delete old `redcap_v*` directories flagged by `check.php`.

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
- The SELinux fix prompt requires typing `YES` and shows exactly which commands will run
  before applying any changes.
