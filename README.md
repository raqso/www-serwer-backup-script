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

1. Install required [restic](https://restic.readthedocs.io/), [resticprofile](https://creativeprojects.github.io/resticprofile/) and [rclone](https://rclone.org/) tools and also setup initial files, with the [installation.sh](./installation.sh) script

```bash
./installation.sh
```

2. Configure [rclone](https://rclone.org/) for cloud backups

```bash
rclone config
```

3. Fill up the ./config.conf file with your own details and also store somewhere safe, the generated `password-file`.

## Launching backup

```bash
./backup.sh
```

You can add this to cron or run manually when needed.

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
