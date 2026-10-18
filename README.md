# Www serwer backup script

It could be used to automate the process of making backups of your www files and mysql database.

## What script does?

* Packs selected directory on your server to [restic](https://restic.readthedocs.io/) repository,
* Same with the selected mysql database,
* Sends it to cloud using [rclone](https://rclone.org/) e.g. Google Drive,
* Removes the oldest backups(on the server and Google Drive) according settings.

## What do you need to start using it

* A Linux server with mysql.
* Any Cloud provider for [rcloud](https://rclone.org/overview/) sync. E.g. for Google Drive you would need a valid Google Drive 'Client ID' and 'Secret client key' created.

## Initial configuration

1. Get the code at a release tag. The latest release is listed at https://github.com/raqso/www-serwer-backup-script/releases, use its tag instead of `v0.1.0` below.

```bash
git clone --branch v0.1.0 https://github.com/raqso/www-serwer-backup-script.git
cd www-serwer-backup-script
```

2. Install required [restic](https://restic.readthedocs.io/), [resticprofile](https://creativeprojects.github.io/resticprofile/) and [rclone](https://rclone.org/) tools and also setup initial files, with the [installation.sh](./installation.sh) script

```bash
./installation.sh
```

3. Configure [rclone](https://rclone.org/) for cloud backups

```bash
rclone config
```

4. Fill up the ./config.conf file with your own details and also store somewhere safe, the generated `password-file`.

## Updating

Fetch the new tags, check out the new release and re-run the installer:

```bash
git fetch --tags
git checkout <new tag>
./installation.sh
```

Re-running `installation.sh` is safe: it keeps your existing `password-file` and `config.conf`. Still, make sure you have a copy of `password-file` stored outside the server before updating.

## Launching backup

```bash
./backup.sh
```

You can add this to cron or run manually when needed. A successful run prints nothing; the full output of each run is saved in `logs/` next to the script, and on failure an ERROR with the end of that log is printed to stderr. Use `./backup.sh -v` to also see the output on the terminal. Only one backup runs at a time; a second one started meanwhile exits with an error.

## Development

Shell scripts are linted with [shellcheck](https://www.shellcheck.net/) via [scripts/shellcheck.sh](./scripts/shellcheck.sh). Enable the versioned pre-commit hook once per clone:

```bash
git config core.hooksPath .githooks
```

The hook requires `shellcheck` installed locally (`brew install shellcheck` or `sudo apt-get install shellcheck`). GitHub Actions runs the same script on every push and pull request.

## Testing

End-to-end tests run the real `installation.sh` and `backup.sh` in Docker, in an environment similar to shared hosting: an Ubuntu container with a non-root user, a MariaDB container with a user that has limited privileges, and an rclone local directory standing in for the cloud.

```bash
./tests/e2e.sh
```

Requirements: Docker and network access (the installer downloads restic, resticprofile and rclone). A run takes about a minute once the images have been pulled. Containers and networks created by the test are removed afterwards, even when it fails.

GitHub Actions runs the same test on every push to `master` and on every pull request.
