# Www serwer backup script

Backs up a website (files and one MySQL/MariaDB database) from a shared hosting account. It uses [restic](https://restic.readthedocs.io/) for the backups, [resticprofile](https://creativeprojects.github.io/resticprofile/) to run it, and [rclone](https://rclone.org/) to copy the result to a cloud (e.g. Google Drive). No root access needed.

## What it does

Everything is done with the `wsb` command in the script directory. Each run of `wsb backup`:

1. Dumps the database (`mysqldump`) into a restic repository on the server (the local repository).
2. Backs up the website directory into the same repository.
3. Removes old snapshots and prunes the repository: keeps 7 daily, 4 weekly and 12 monthly snapshots (see [Retention](#retention)).
4. Checks the local repository.
5. Only if the check passed, mirrors the local repository to the cloud with `rclone sync`.

If one step fails, the next ones still run (except the upload after a failed check), and the script exits with an error at the end.

Not backed up by default: `cache`, `log`, `tmp`, `img/tmp` and `img/**/*_default.jpg` inside the website directory (see [Excludes](#excludes)).

## Requirements

* Linux on x86_64 (amd64) or aarch64 (arm64).
* `bash` 4.2 or newer, `curl` or `wget`, `sha256sum` or `shasum`, `tar`, `gzip`, `bzip2`, `unzip` (the installer checks these).
* `mysqldump` from the MySQL/MariaDB client, and a database user that can read the database.
* `crontab` access, to run backups automatically.
* Free disk space for the local repository. It lives on the same account, so it counts against your quota.
* A cloud account supported by [rclone](https://rclone.org/overview/). For Google Drive you need a 'Client ID' and 'Client Secret' of your own.

## Initial configuration

1. Download and install the latest release (works with `curl` or `wget`, no git needed):

```bash
(curl -fsSL https://github.com/raqso/www-serwer-backup-script/releases/latest/download/get.sh || wget -qO- https://github.com/raqso/www-serwer-backup-script/releases/latest/download/get.sh) | bash
cd ~/www-serwer-backup-script
```

This puts the program files into `~/www-serwer-backup-script` and runs `./wsb install`, which installs [restic](https://restic.readthedocs.io/), [resticprofile](https://creativeprojects.github.io/resticprofile/) and [rclone](https://rclone.org/) into `~/bin` and creates the initial files. To install a specific release, end the command with `| WSB_VERSION=v0.x.y bash` instead of `| bash`; to use another directory, set `WSB_DIR=/path` the same way.

2. Configure [rclone](https://rclone.org/) for cloud backups:

```bash
rclone config
```

3. Fill in `./config.conf` (see [Configuration](#configuration)).

4. Copy the generated `password-file` somewhere outside the server (see [Security notes](#security-notes)).

5. Run `./wsb backup -v` once to check that everything works, then [schedule it](#running-and-cron).

## Configuration

`config.conf` is created by the installer from [config.conf.example](./config.conf.example). It is a shell file: keep the `VARIABLE='value'` form.

| Variable | Meaning | Example |
| --- | --- | --- |
| `DIRECTORY_TO_BACKUP` | Website directory to back up. Must exist. | `/home/user/domains/example.com/public_html` |
| `LOCAL_BACKUPS_PATH` | Where the local restic repository is kept. Absolute path. Use a folder outside the script directory. | `/home/user/backups/my-site` |
| `RCLONE_REMOTE_NAME` | Cloud destination as `remote:folder` (the remote name comes from `rclone config`). An absolute local path also works. | `gdrive:backups/my-site` |
| `RCLONE_BWLIMIT` | Optional upload speed limit, any rclone `--bwlimit` value. Empty = unlimited. | `10M` |
| `DB_HOST` | Database host. | `localhost` |
| `DB_NAME` | Database name. | `my_site_db` |
| `DB_USER` | Database user. | `my_site_user` |
| `DB_PASS` | Database password. | |

`DIRECTORY_TO_BACKUP`, `LOCAL_BACKUPS_PATH`, `RCLONE_REMOTE_NAME`, `DB_NAME` and `DB_USER` must be set, otherwise `wsb backup` stops with an error. `DB_HOST` defaults to `localhost` in the example file.

**Warning:** the `RCLONE_REMOTE_NAME` folder is mirrored with `rclone sync`: everything in it that is not part of the backup gets deleted. Use a dedicated, empty folder, never the remote root. `wsb backup` refuses `gdrive:`, `gdrive:/` and a bare name like `gdrive`.

## Security notes

* **Keep a copy of `password-file` outside the server** (a password manager, an encrypted USB stick). It is the key to the repository. Without it the backups cannot be restored, and if the server is lost, the key is lost with it. The installer never overwrites an existing `password-file`.
* **The cloud copy is a mirror, not a separate history.** `rclone sync` makes the cloud folder identical to the local repository. If the local repository is deleted or damaged in a way the check does not detect, the next sync can copy that to the cloud too. `wsb backup` guards against two cases: it does not upload when the check fails, and it does not create a new repository when the local one is missing but the cloud has one. This is a known limitation: keep the cloud account itself secure, and do not delete the local repository by hand.
* `config.conf` contains the database password. The installer sets `config.conf` and `password-file` to mode 600, and `logs/` is private to your user. Do not loosen this.
* The database credentials reach `mysqldump` through an option file (`mysqldump.cnf`, mode 600, deleted after the run), never on a command line that other users of the server could see with `ps`. Any characters work in `DB_PASS`.
* `wsb install` checks every downloaded binary against the official SHA-256 file of its release (`SHA256SUMS` for restic and rclone, `checksums.txt` for resticprofile) before it is put into `~/bin`. On a mismatch or a missing entry it stops and leaves `~/bin` unchanged. This catches damaged and tampered downloads, but the checksum file comes from the same server as the binary; GPG signatures are not checked.
* The install command and `wsb update` trust GitHub over HTTPS: `get.sh` and the source archive of the release are downloaded from github.com (and raw.githubusercontent.com for `wsb update`) and are not otherwise verified. To read `get.sh` before running it, download it first and run it with `bash get.sh`.

## Running and cron

```bash
./wsb backup       # quiet when everything is fine
./wsb backup -v    # also show the output on the terminal
./wsb backup -h    # usage
./wsb --version
```

* A successful run prints nothing, so cron sends no mail. On failure an `ERROR` message with the end of the log goes to stderr, which cron mails to you.
* Exit codes: `0` success (also for `-h`), `1` a step or a check failed, a required tool is missing, or an unknown argument was given.
* The full output of every run is saved in `logs/` next to the script (`logs/backup-<date>-<time>-<pid>.log`). Logs older than 30 days are deleted.
* One backup runs at a time. A second one started meanwhile exits with an error. The lock is `backup.lock` in the script directory.
* The backup runs with low priority (`nice -n 15`), so it gives way to your website.

Example: run daily at 3:15 (edit with `crontab -e`, use the real path):

```
15 3 * * * /home/USER/www-serwer-backup-script/wsb backup
```

Cron has a minimal `PATH`. `wsb` adds `~/bin` itself, so you do not need to set it.

`backup.sh` and `installation.sh` still work (they run `wsb backup` and `wsb install` with the same arguments), so existing cron entries keep working. They are deprecated and will be removed in v1.0: switch your cron entry to `wsb backup`.

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

1. Install wsb again with the command from [Initial configuration](#initial-configuration) (step 1).
2. Put your saved copy of `password-file` into the script directory, replacing the new one, then `chmod 600 password-file`.
3. Run `rclone config` and create the same remote as before.
4. Copy the repository from the cloud to the server:

   ```bash
   ~/bin/rclone copy gdrive:backups/my-site /home/USER/backups/my-site
   ```

5. Restore the files and the database with steps 1 to 3 above.
6. Fill in `config.conf` and run `./wsb backup -v`. It continues the existing history.

`wsb backup` prints this same `rclone copy` command when it finds the cloud copy but no local repository.

**Test your backups from time to time.** Restore into a temporary directory and a throwaway database, as above, and check that the files and data are there. You can also run `~/bin/restic -r <repo> --password-file ./password-file check`.

## Retention

Defined in the `maintenance` section of [profiles.yaml](./profiles.yaml): `keep-daily: 7`, `keep-weekly: 4`, `keep-monthly: 12`. The database and files snapshots are counted separately, and the latest snapshot of each is always kept. Old data is removed from the local repository and, with the next sync, from the cloud.

## Excludes

Defined in the `www` section of [profiles.yaml](./profiles.yaml), relative to `DIRECTORY_TO_BACKUP`:

* `cache`, `log`, `tmp`
* `img/tmp` (PrestaShop)
* `img/**/*_default.jpg` (PrestaShop)

If your site is not PrestaShop, the last two rules do nothing. To add your own cache and temp directories, or change the retention, see [Local changes](#local-changes-to-retention-and-excludes).

## Local changes to retention and excludes

Do not edit `profiles.yaml`: every update replaces it. Put your changes into a `.yaml` file in `profiles.d/` instead (created by `wsb install`, never touched by updates). Every `profiles.d/*.yaml` file is read after `profiles.yaml` and its values replace the ones there. A list such as `exclude` is replaced as a whole, so repeat the entries you want to keep.

Example `profiles.d/local.yaml` (the same example is in `profiles.d/README.txt`):

```yaml
maintenance:
  forget:
    keep-daily: 14
www:
  backup:
    exclude:
      - "$DIRECTORY_TO_BACKUP/cache"
      - "$DIRECTORY_TO_BACKUP/var/tmp"
```

Check the result with `./wsb backup -v`, or see the generated restic commands without running them:

```bash
(set -a && . ./config.conf && ~/bin/resticprofile --dry-run --name maintenance forget)
```

## Updating

Run the install command from [Initial configuration](#initial-configuration) again, or from the script directory:

```bash
./wsb update                    # latest release
./wsb update --version v0.x.y   # a specific release
```

Both replace only the program files (`wsb`, `backup.sh`, `installation.sh`, `profiles.yaml`, `config.conf.example`, `README.md`, `LICENSE`), then run `wsb install`, and print the old and new version. If your `profiles.yaml` differs from the new one, the old one is kept as `profiles.yaml.bak-<date>-<time>`: move any changes you made into `profiles.d/` (see [Local changes](#local-changes-to-retention-and-excludes)) and delete the copy.

Re-running `wsb install` is safe: it keeps your existing `password-file`, `config.conf` and `profiles.d/`, and updates restic, resticprofile and rclone in `~/bin` to their latest releases (tools that are already up to date are skipped). It does not use the GitHub API, so its rate limit for shared server IPs does not apply. Still, make sure you have a copy of `password-file` stored outside the server before updating.

### Moving from a git clone

Older instructions installed wsb with `git clone` into `~/www-serwer-backup-script`. Run the install command (add `WSB_DIR=/path` before `bash` if your clone is elsewhere). It updates the directory in place, without git: your `config.conf`, `password-file`, `profiles.d/`, `logs/` and cron entry keep working. An edited `profiles.yaml` is saved as `profiles.yaml.bak-*` (see above). The `.git` directory is left alone and no longer used; you can delete it.

## Development

`wsb` is generated with [Bashly](https://bashly.dev) from `src/` (`src/bashly.yml` defines the commands and flags, `src/*_command.sh` hold the code, `src/lib/` shared functions; settings in `settings.yml`). Do not edit `wsb` by hand. After changing `src/`, regenerate it and commit both:

```bash
./scripts/generate.sh
```

The script runs a pinned Bashly version in Docker, so no local Ruby is needed. The generated `wsb` is committed because servers usually have no Ruby; CI fails when it is out of date with `src/`.

Shell scripts are linted with [shellcheck](https://www.shellcheck.net/) via [scripts/shellcheck.sh](./scripts/shellcheck.sh). Enable the versioned pre-commit hook once per clone:

```bash
git config core.hooksPath .githooks
```

The hook requires `shellcheck` installed locally (`brew install shellcheck` or `sudo apt-get install shellcheck`). GitHub Actions runs the same script on every push and pull request.

`get.sh` is a standalone bash script (not generated by Bashly): it runs from a pipe before `wsb` exists. It carries a small copy of the download helpers in `src/lib/download.sh`; keep the two in sync.

Releasing: after creating the GitHub release for a tag, attach `get.sh` from that tag, so the `releases/latest/download/get.sh` URL of the install command works:

```bash
gh release upload <tag> get.sh
```

## Testing

End-to-end tests run the real `wsb install` and `wsb backup` in Docker, in an environment similar to shared hosting: an Ubuntu container with a non-root user, a MariaDB container with a user that has limited privileges, and an rclone local directory standing in for the cloud. They include restoring the files and the database from the cloud copy.

```bash
./tests/e2e.sh
```

Requirements: Docker and network access (the installer downloads restic, resticprofile and rclone). A run takes under two minutes once the images have been pulled. Containers and networks created by the test are removed afterwards, even when it fails. The app container uses the Docker host's architecture; set `E2E_PLATFORM=linux/amd64` or `linux/arm64` to choose one.

The `get.sh` scenarios install from a source archive of the checked-out commit plus uncommitted changes to tracked files (`git stash create` + `git archive`; `git add` new files first), passed to `get.sh` with the test-only `WSB_TARBALL=/path/to.tar.gz` instead of a release download. `wsb update` is tested with a `curl` shim that serves the local `get.sh` for the raw.githubusercontent.com URL; one scenario downloads the real v0.4.0 release.

`./tests/download_test.sh` checks the download helpers offline (release tag from the redirect, checksum lookup and verification).

GitHub Actions runs the end-to-end test on amd64 and arm64 on every push to `master` and on every pull request.
