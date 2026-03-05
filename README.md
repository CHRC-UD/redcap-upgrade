## REDCap Easy Upgrade CLI

This folder contains a standalone command‑line helper for REDCap’s **Easy Upgrade** feature.  
It mirrors what the web UI does, but lets you run the upgrade as a privileged admin user
instead of the web server account.

### Files

- `redcap_easy_upgrade.sh` – main upgrade script (bash).

### Requirements

- Bash 4+, `php` (CLI), `curl`, `python3`, `unzip`, `mysql` (CLI).
- Access to the REDCap webroot (defaults to `/var/www/html/redcap`).
- A MySQL user with **CREATE, DROP, ALTER, REFERENCES** on the REDCap database.
- A REDCap Community account (VUMC) if you want the script to download upgrade zips for you.

### Basic usage

Before running it the first time, open `redcap_easy_upgrade.sh` and review the **configuration block at the top** (`REDCAP_ROOT`, MySQL and Community credential variables). In most cases the defaults will work, but this is where you override anything that differs on your system.

From this directory:

```bash
sudo ./redcap_easy_upgrade.sh
```

The script will:

1. Read your current REDCap version via `redcap_connect.php`.
2. Call the consortium endpoint to discover newer versions.
3. Let you **select a target version** from the list.
4. Download and install the new `redcap_v<version>/` directory (unless `--skip-download`).
5. Generate and execute the same upgrade SQL that `upgrade.php` would run.
6. Optionally help tighten Unix permissions and SELinux contexts on the REDCap webroot.

To see which versions are available without upgrading:

```bash
./redcap_easy_upgrade.sh --check-versions
```

To preview the SQL only:

```bash
./redcap_easy_upgrade.sh --dry-run 15.5.36
```

### Important safety notes

- **Never** run this script as the web server user (e.g. `apache`, `www-data`, `nginx`).  
  Run it as `root` or another admin account.
- Keep regular backups of your REDCap database and webroot before performing upgrades.
- If you use a proxy or have SELinux enforcing, ensure outbound access to  
  `https://redcap.vumc.org/plugins/redcap_consortium/versions.php` is allowed.  
  Set `REDCAP_UPGRADE_PROXY=http://proxy.example.com:3128` (or the standard  
  `https_proxy` / `HTTPS_PROXY` / `http_proxy` / `HTTP_PROXY` variables) to  
  route all curl requests through a proxy.

