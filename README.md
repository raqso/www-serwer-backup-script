# Www serwer backup script

Backs up a website (files and one MySQL/MariaDB database) from a shared hosting account. It uses [restic](https://restic.readthedocs.io/) for the backups, [resticprofile](https://creativeprojects.github.io/resticprofile/) to run it, and [rclone](https://rclone.org/) to copy the result to a cloud (e.g. Google Drive). No root access needed.

## What it does

Each run of `backup.sh`:

1. Dumps the database (`mysqldump`) into a restic repository on the server (the local repository).
2. Backs up the website directory into the same repository.
3. Removes old snapshots and prunes the repository: keeps 7 daily, 4 weekly and 12 monthly snapshots (see [Retention](#retention)).
4. Checks the local repository.
5. Only if the check passed, mirrors the local repository to the cloud with `rclone sync`.

If one step fails, the next ones still run (except the upload after a failed check), and the script exits with an error at the end.

Not backed up by default: `cache`, `log`, `tmp`, `img/tmp` and `img/**/*_default.jpg` inside the website directory (see [Excludes](#excludes)).

## Requirements

* Linux x86_64 (amd64). Other architectures (e.g. arm64) are not supported yet.
* `bash`, `curl`, `bzip2`, `unzip`, `tar` (the installer checks these).
* `mysqldump` from the MySQL/MariaDB client, and a database user that can read the database.
* `crontab` access, to run backups automatically.
* Free disk space for the local repository. It lives on the same account, so it counts against your quota.
* A cloud account supported by [rclone](https://rclone.org/overview/). For Google Drive you need a 'Client ID' and 'Client Secret' of your own.

## Initial configuration

1. Get the code at a release tag. The latest release is listed at https://github.com/raqso/www-serwer-backup-script/releases, use its tag instead of `v0.3.0` below.

```bash
git clone --branch v0.3.0 https://github.com/raqso/www-serwer-backup-script.git
cd www-serwer-backup-script
```

2. Install [restic](https://restic.readthedocs.io/), [resticprofile](https://creativeprojects.github.io/resticprofile/) and [rclone](https://rclone.org/) into `~/bin` and create the initial files, with the [installation.sh](./installation.sh) script:

```bash
./installation.sh
```

3. Configure [rclone](https://rclone.org/) for cloud backups:

```bash
rclone config
```

4. Fill in `./config.conf` (see [Configuration](#configuration)).

5. Copy the generated `password-file` somewhere outside the server (see [Security notes](#security-notes)).

6. Run `./backup.sh -v` once to check that everything works, then [schedule it](#running-and-cron).

## Configuration

`config.conf` is created by the installer from [config.conf.example](./config.conf.example). It is a shell file: keep the `VARIABLE='value'` form.

| Variable | Meaning | Example |
| --- | --- | --- |
| `DIRECTORY_TO_BACKUP` | Website directory to back up. Must exist. | `/home/user/domains/example.com/public_html` |
| `LOCAL_BACKUPS_PATH` | Where the local restic repository is kept. Absolute path. Use a folder outside the script directory, so it can never end up in git. | `/home/user/backups/my-site` |
| `RCLONE_REMOTE_NAME` | Cloud destination as `remote:folder` (the remote name comes from `rclone config`). An absolute local path also works. | `gdrive:backups/my-site` |
| `RCLONE_BWLIMIT` | Optional upload speed limit, any rclone `--bwlimit` value. Empty = unlimited. | `10M` |
| `DB_HOST` | Database host. | `localhost` |
| `DB_NAME` | Database name. | `my_site_db` |
| `DB_USER` | Database user. | `my_site_user` |
| `DB_PASS` | Database password. | |

`DIRECTORY_TO_BACKUP`, `LOCAL_BACKUPS_PATH`, `RCLONE_REMOTE_NAME`, `DB_NAME` and `DB_USER` must be set, otherwise `backup.sh` stops with an error. `DB_HOST` defaults to `localhost` in the example file.

**Warning:** the `RCLONE_REMOTE_NAME` folder is mirrored with `rclone sync`: everything in it that is not part of the backup gets deleted. Use a dedicated, empty folder, never the remote root. `backup.sh` refuses `gdrive:`, `gdrive:/` and a bare name like `gdrive`.

## Security notes

* **Keep a copy of `password-file` outside the server** (a password manager, an encrypted USB stick). It is the key to the repository. Without it the backups cannot be restored, and if the server is lost, the key is lost with it. The installer never overwrites an existing `password-file`.
* **The cloud copy is a mirror, not a separate history.** `rclone sync` makes the cloud folder identical to the local repository. If the local repository is deleted or damaged in a way the check does not detect, the next sync can copy that to the cloud too. `backup.sh` guards against two cases: it does not upload when the check fails, and it does not create a new repository when the local one is missing but the cloud has one. This is a known limitation: keep the cloud account itself secure, and do not delete the local repository by hand.
* `config.conf` contains the database password. The installer sets `config.conf` and `password-file` to mode 600, and `logs/` is private to your user. Do not loosen this.

## Running and cron

```bash
./backup.sh        # quiet when everything is fine
./backup.sh -v     # also show the output on the terminal
./backup.sh -h     # usage
```

* A successful run prints nothing, so cron sends no mail. On failure an `ERROR` message with the end of the log goes to stderr, which cron mails to you.
* Exit codes: `0` success (also for `-h`), `1` a step or a check failed, `2` unknown argument.
* The full output of every run is saved in `logs/` next to the script (`logs/backup-<date>-<time>-<pid>.log`). Logs older than 30 days are deleted.
* One backup runs at a time. A second one started meanwhile exits with an error. The lock is `backup.lock` in the script directory.
* The backup runs with low priority (`nice -n 15`), so it gives way to your website.

Example: run daily at 3:15 (edit with `crontab -e`, use the real path):

```
15 3 * * * /home/USER/www-serwer-backup-script/backup.sh
```

Cron has a minimal `PATH`. `backup.sh` adds `~/bin` itself, so you do not need to set it.

## Restore

Run these from the script directory (where `password-file` is). Replace `/home/USER/backups/my-site` with your `LOCAL_BACKUPS_PATH`. The two backups are tagged `www` (files) and `db` (database dump).

**1. List snapshots**

```bash
~/bin/restic -r /home/USER/backups/my-site --password-file ./password-file snapshots
```

**2. Restore the files** into a new, empty directory:

```bash
~/bin/restic -r /home/USER/backups/my-site --password-file ./password-file \
  restore latest --tag www --target /home/USER/restore
```

The files appear under their original path, e.g. `/home/USER/restore/home/USER/domains/example.com/public_html`. Check them, then copy what you need back. Use a snapshot ID from step 1 instead of `latest` to go back to an older version.

**3. Restore the database** into an empty database (create it first):

```bash
~/bin/restic -r /home/USER/backups/my-site --password-file ./password-file \
  dump latest --tag db database_dump.sql | mysql -u DB_USER -p DB_NAME
```

**4. Restore after losing the server** (the local repository is gone, the cloud copy is fine):

1. Get the code again and run the installer, as in [Initial configuration](#initial-configuration) (steps 1 and 2).
2. Put your saved copy of `password-file` into the script directory, replacing the new one, then `chmod 600 password-file`.
3. Run `rclone config` and create the same remote as before.
4. Copy the repository from the cloud to the server:

   ```bash
   ~/bin/rclone copy gdrive:backups/my-site /home/USER/backups/my-site
   ```

5. Restore the files and the database with steps 1 to 3 above.
6. Fill in `config.conf` and run `./backup.sh -v`. It continues the existing history.

`backup.sh` prints this same `rclone copy` command when it finds the cloud copy but no local repository.

**Test your backups from time to time.** Restore into a temporary directory and a throwaway database, as above, and check that the files and data are there. You can also run `~/bin/restic -r <repo> --password-file ./password-file check`.

## Retention

Defined in the `maintenance` section of [profiles.yaml](./profiles.yaml): `keep-daily: 7`, `keep-weekly: 4`, `keep-monthly: 12`. The database and files snapshots are counted separately, and the latest snapshot of each is always kept. Old data is removed from the local repository and, with the next sync, from the cloud.

## Excludes

Defined in the `www` section of [profiles.yaml](./profiles.yaml), relative to `DIRECTORY_TO_BACKUP`:

* `cache`, `log`, `tmp`
* `img/tmp` (PrestaShop)
* `img/**/*_default.jpg` (PrestaShop)

If your site is not PrestaShop, the last two rules do nothing. Add your own cache and temp directories the same way.

Retention and excludes can only be changed by editing `profiles.yaml`. That file is tracked by git, so a local edit conflicts with `git checkout <new tag>` when updating. Keep such edits small, and re-apply them after an update (e.g. `git stash` before, `git stash pop` after).

## Updating

Fetch the new tags, check out the new release and re-run the installer:

```bash
git fetch --tags
git checkout <new tag>
./installation.sh
```

Re-running `installation.sh` is safe: it keeps your existing `password-file` and `config.conf`, and updates restic, resticprofile and rclone. Still, make sure you have a copy of `password-file` stored outside the server before updating.

## Development

Shell scripts are linted with [shellcheck](https://www.shellcheck.net/) via [scripts/shellcheck.sh](./scripts/shellcheck.sh). Enable the versioned pre-commit hook once per clone:

```bash
git config core.hooksPath .githooks
```

The hook requires `shellcheck` installed locally (`brew install shellcheck` or `sudo apt-get install shellcheck`). GitHub Actions runs the same script on every push and pull request.

## Testing

End-to-end tests run the real `installation.sh` and `backup.sh` in Docker, in an environment similar to shared hosting: an Ubuntu container with a non-root user, a MariaDB container with a user that has limited privileges, and an rclone local directory standing in for the cloud. They include restoring the files and the database from the cloud copy.

```bash
./tests/e2e.sh
```

Requirements: Docker and network access (the installer downloads restic, resticprofile and rclone). A run takes under two minutes once the images have been pulled. Containers and networks created by the test are removed afterwards, even when it fails.

GitHub Actions runs the same test on every push to `master` and on every pull request.
