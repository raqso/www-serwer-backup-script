#!/bin/bash
# End-to-end test: real `wsb install` + `wsb backup` in a shared-hosting-like
# Docker setup (non-root user, limited DB privileges, rclone local "cloud").
# Usage: ./tests/e2e.sh   (needs Docker and network access)
# E2E_PLATFORM=linux/amd64 or linux/arm64 sets the app container platform (default: the Docker host's).
# Add a scenario: write a scenario_* function, then add a run_scenario line at the bottom.
# shellcheck disable=SC2317,SC2329 # cleanup and scenario_* are invoked indirectly (trap, run_scenario)

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ID="www-backup-e2e-$$"
NET="$ID-net"
DB="$ID-db"
APP="$ID-app"
PLATFORM="${E2E_PLATFORM:-linux/$(docker version --format '{{.Server.Arch}}')}"

DB_ROOT_PASS='rootpass'
DB_NAME='site'
DB_USER='siteuser'
DB_PASS='sitepass'

HOME_DIR='/home/tester'
APP_DIR="$HOME_DIR/app"
WWW_DIR="$HOME_DIR/www"
LOCAL_REPO="$HOME_DIR/backups"
CLOUD_REPO="$HOME_DIR/cloud/backups"
RESTIC="$HOME_DIR/bin/restic --password-file $APP_DIR/password-file"
# get.sh installs into ~/www-serwer-backup-script by default.
GET_DIR="$HOME_DIR/www-serwer-backup-script"
# Source tarball of the working tree, laid out like a GitHub release archive (one top directory).
TARBALL_DIR="$(mktemp -d)"
TARBALL=/tmp/wsb.tar.gz

FAILED=0
SUMMARY=""

cleanup() {
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$TARBALL_DIR"
}
trap cleanup EXIT

log() { echo "==> $*"; }

# Run a command as the non-root tester user inside the app container.
as_tester() { docker exec -u tester -w "$APP_DIR" "$APP" bash -c "$1"; }

db_root() { docker exec -i "$DB" mariadb -uroot -p"$DB_ROOT_PASS" "$@"; }

setup() {
  log "Starting containers"
  docker network create "$NET" >/dev/null || return 1
  docker run -d --name "$DB" --network "$NET" -e MARIADB_ROOT_PASSWORD="$DB_ROOT_PASS" \
    -e MARIADB_DATABASE="$DB_NAME" mariadb:11.4 >/dev/null || return 1
  log "App container platform: $PLATFORM"
  docker run -d --name "$APP" --network "$NET" --platform "$PLATFORM" \
    -v "$REPO_DIR:/src:ro" ubuntu:24.04 sleep infinity >/dev/null || return 1

  log "Installing OS packages (as root, like the hosting provider would)"
  docker exec "$APP" bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl wget ca-certificates bzip2 unzip mariadb-client >/dev/null && useradd -m -s /bin/bash tester \
    && install -d -o tester -g tester $APP_DIR" || return 1

  log "Seeding website directory and copying repo scripts"
  as_tester "
    set -e
    cp /src/wsb /src/installation.sh /src/backup.sh /src/profiles.yaml /src/config.conf.example $APP_DIR/
    cd $HOME_DIR && mkdir -p www/css www/img/p/1 www/cache www/log www/tmp www/img/tmp
    echo '<?php echo \"hello\";' > www/index.php
    echo 'body{}' > www/css/style.css
    head -c 100000 /dev/urandom > www/img/p/1/photo.jpg
    head -c 1000 /dev/urandom > www/img/p/1/photo_default.jpg
    echo cached > www/cache/page.html
    echo log > www/log/error.log
    echo tmp > www/tmp/upload.tmp
    echo tmp > www/img/tmp/resize.jpg
  " || return 1

  log "Building the source tarball for get.sh"
  # 'git stash create' adds uncommitted changes to tracked files (it does not touch the stash
  # list); new files must be added to git first. Empty in a clean checkout (CI): HEAD is used.
  local tree
  tree=$(git -C "$REPO_DIR" stash create) || return 1
  git -C "$REPO_DIR" archive --format=tar.gz --prefix=www-serwer-backup-script-e2e/ \
    -o "$TARBALL_DIR/wsb.tar.gz" "${tree:-HEAD}" || return 1
  docker cp "$TARBALL_DIR/wsb.tar.gz" "$APP:$TARBALL" && docker exec "$APP" chmod 644 "$TARBALL" || return 1

  log "Waiting for MariaDB"
  local i
  for i in $(seq 60); do
    docker exec "$DB" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && break
    [ "$i" = 60 ] && return 1
    sleep 1
  done

  log "Creating shared-hosting DB user and seed data"
  db_root "$DB_NAME" <<SQL || return 1
CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';
GRANT SELECT, LOCK TABLES, SHOW VIEW, TRIGGER ON \`$DB_NAME\`.* TO '$DB_USER'@'%';
CREATE TABLE posts (id INT PRIMARY KEY AUTO_INCREMENT, title VARCHAR(100));
INSERT INTO posts (title) SELECT CONCAT('post ', seq) FROM seq_1_to_50;
SQL
}

# Installer run from a login shell, like a user over SSH.
install_as_tester() { docker exec -u tester -w "$APP_DIR" "$APP" bash -lc './wsb install'; }

scenario_first_install_generates_password_file() {
  install_as_tester || return 1
  as_tester "test -s password-file" || { echo "password-file is empty"; return 1; }
  local modes
  modes=$(as_tester "stat -c '%n %a' password-file config.conf") || return 1
  [ "$modes" = $'password-file 600\nconfig.conf 600' ] || { echo "expected mode 600, got: $modes"; return 1; }
  local tool
  for tool in restic resticprofile rclone; do
    as_tester "$HOME_DIR/bin/$tool version >/dev/null" || { echo "$tool not runnable from ~/bin"; return 1; }
  done
  # The binaries match the container's architecture (no emulation fallback).
  as_tester "$HOME_DIR/bin/restic version" | grep -qF "$PLATFORM" || { echo "restic is not a $PLATFORM binary"; return 1; }
  as_tester "stat -c %a profiles.d && test -s profiles.d/README.txt" | grep -qx 700 || { echo "profiles.d/ must be 700 and have a README.txt"; return 1; }
}

# The tools are downloaded again into ~/bin with wget alone (curl removed) and are verified.
scenario_install_with_wget_only() {
  local out rc=0
  docker exec "$APP" mv /usr/bin/curl /usr/bin/curl.off || return 1
  as_tester "rm $HOME_DIR/bin/restic $HOME_DIR/bin/resticprofile $HOME_DIR/bin/rclone" || rc=1
  out=$(install_as_tester 2>&1) || { echo "$out"; echo "wsb install with wget failed"; rc=1; }
  docker exec "$APP" mv /usr/bin/curl.off /usr/bin/curl || return 1
  local tool
  for tool in restic resticprofile rclone; do
    grep -q "Installing $tool " <<<"$out" || { echo "$tool was not installed: $out"; rc=1; }
    as_tester "$HOME_DIR/bin/$tool version >/dev/null" || { echo "$tool not runnable from ~/bin"; rc=1; }
  done
  return "$rc"
}

# A download that does not match the official checksum must not reach ~/bin. A curl shim
# appends a byte to every downloaded .zip (rclone), and ~/bin/rclone is a fake old version.
scenario_bad_checksum_not_installed() {
  local before out rc=0
  # wsb downloads with: curl -fsSL -o <file> <url>
  docker exec -i -u tester "$APP" sh -c "mkdir -p $HOME_DIR/shim && cat >$HOME_DIR/shim/curl && chmod +x $HOME_DIR/shim/curl" <<'EOF' || return 1
#!/bin/sh
/usr/bin/curl "$@" || exit
case "$2 $4" in -o\ *.zip) printf x >>"$3" ;; esac
EOF
  as_tester "printf '#!/bin/sh\necho rclone v0.0.1\n' >$HOME_DIR/bin/rclone" || return 1
  before=$(as_tester "sha256sum $HOME_DIR/bin/*") || return 1
  if out=$(docker exec -u tester -w "$APP_DIR" "$APP" bash -lc "PATH=$HOME_DIR/shim:\$PATH ./wsb install" 2>&1); then
    echo "wsb install succeeded with a corrupted download"; rc=1
  fi
  echo "$out" | tail -n 3
  grep -q 'checksum mismatch for rclone-v.*\.zip' <<<"$out" || { echo "no checksum mismatch message"; rc=1; }
  [ "$(as_tester "sha256sum $HOME_DIR/bin/*")" = "$before" ] || { echo "$HOME_DIR/bin changed"; rc=1; }
  as_tester "rm -r $HOME_DIR/shim"
  install_as_tester >/dev/null || { echo "wsb install without the shim failed"; rc=1; }
  as_tester "$HOME_DIR/bin/rclone version | grep -qv v0.0.1" || { echo "rclone not restored"; rc=1; }
  return "$rc"
}

# The commented example in profiles.d/README.txt, saved as local.yaml, overrides the retention
# and replaces the exclude list.
scenario_profiles_d_override() {
  local out rc=0
  as_tester "sed -n '/^# maintenance:/,\$ s/^# //p' profiles.d/README.txt >profiles.d/local.yaml" || return 1
  out=$(as_tester "set -a && . ./config.conf && export PATH=$HOME_DIR/bin:\$PATH && {
    resticprofile --dry-run --name maintenance forget && resticprofile --dry-run --name www backup; } 2>&1") || rc=1
  as_tester "rm profiles.d/local.yaml"
  echo "$out" | grep dry-run
  grep 'restic forget' <<<"$out" | grep -q -- '--keep-daily=14 --keep-monthly=12 --keep-weekly=4' || { echo "retention not overridden"; rc=1; }
  local excludes
  excludes=$(grep 'restic backup' <<<"$out" | grep -o -- '--exclude=[^ ]*' | tr '\n' ' ')
  [ "$excludes" = "--exclude=$WWW_DIR/cache --exclude=$WWW_DIR/var/tmp " ] || { echo "exclude list not replaced: $excludes"; rc=1; }
  return "$rc"
}

# get_sh <env assignments>: get.sh piped into bash from a login shell, like the README one-liner.
get_sh() { docker exec -u tester -w "$HOME_DIR" "$APP" bash -lc "cat /src/get.sh | $1 bash"; }

# The one-liner on a server without git: program files only, with exec bits, then wsb install.
scenario_get_sh_fresh_install() {
  local out rc=0
  docker exec "$APP" sh -c '! command -v git' || { echo "git must not be installed in the container"; return 1; }
  # A truncated download runs nothing: everything is in main(), called on the last line.
  as_tester "sed '\$d' /src/get.sh | WSB_TARBALL=$TARBALL bash" || { echo "get.sh without its last line failed"; rc=1; }
  as_tester "head -c 2000 /src/get.sh | WSB_TARBALL=$TARBALL bash 2>/dev/null" && { echo "half a get.sh succeeded"; rc=1; }
  as_tester "test ! -e $GET_DIR" || { echo "truncated get.sh created $GET_DIR"; return 1; }
  out=$(get_sh "WSB_TARBALL=$TARBALL" 2>&1) || { echo "$out"; echo "get.sh failed"; return 1; }
  echo "$out" | tail -n 8
  grep -q "Installed wsb v[0-9.]* into $GET_DIR" <<<"$out" || { echo "no install message"; rc=1; }
  grep -q 'rclone config' <<<"$out" || { echo "no next steps"; rc=1; }
  [ "$(as_tester "cd $GET_DIR && stat -c '%n %a' wsb backup.sh installation.sh")" = $'wsb 755\nbackup.sh 755\ninstallation.sh 755' ] ||
    { echo "program files missing or not executable"; rc=1; }
  as_tester "cd $GET_DIR && test -s profiles.yaml && test -s README.md && test -s LICENSE && test -s password-file && test -e config.conf && test -d profiles.d" ||
    { echo "files missing in $GET_DIR"; rc=1; }
  as_tester "test ! -e $GET_DIR/src && test ! -e $GET_DIR/tests && test ! -e $GET_DIR/get.sh" || { echo "non-program files copied"; rc=1; }
  [ "$(as_tester "$GET_DIR/wsb --version")" = "$(as_tester "/src/wsb --version")" ] || { echo "wrong wsb version"; rc=1; }
  return "$rc"
}

# Without curl: the latest tag is read with wget; a missing release fails before anything is written.
scenario_get_sh_wget_only() {
  local out dir="$HOME_DIR/wsb-wget" rc=0
  docker exec "$APP" mv /usr/bin/curl /usr/bin/curl.off || return 1
  out=$(get_sh "WSB_DIR=$dir WSB_TARBALL=$TARBALL" 2>&1) || { echo "$out"; echo "get.sh with wget failed"; rc=1; }
  grep -q "Installed wsb v[0-9]*\.[0-9.]* into $dir" <<<"$out" || { echo "latest tag not resolved: $out"; rc=1; }
  out=$(get_sh "WSB_DIR=$dir-missing WSB_VERSION=v0.0.0" 2>&1) && { echo "get.sh succeeded for a missing release"; rc=1; }
  grep -q 'downloading wsb v0.0.0 failed' <<<"$out" || { echo "no download error: $out"; rc=1; }
  docker exec "$APP" mv /usr/bin/curl.off /usr/bin/curl || return 1
  as_tester "test ! -e $dir-missing" || { echo "$dir-missing was created"; rc=1; }
  as_tester "rm -rf $dir"
  return "$rc"
}

# A real release download (v0.4.0, the first one with wsb), then an update to this version:
# local files are kept, versions are reported, the changed profiles.yaml is backed up once.
scenario_get_sh_update_keeps_local_files() {
  local out before after dir="$HOME_DIR/wsb-update" rc=0
  local_files() { as_tester "cd $dir && sha256sum config.conf password-file profiles.d/local.yaml logs/old.log"; }
  get_sh "WSB_DIR=$dir WSB_VERSION=v0.4.0" >/dev/null 2>&1 || { echo "installing v0.4.0 failed"; return 1; }
  as_tester "cd $dir && echo \"DB_NAME='kept'\" >>config.conf && mkdir -p profiles.d logs && echo 'x: 1' >profiles.d/local.yaml && echo log >logs/old.log" || return 1
  before=$(local_files) || return 1
  out=$(get_sh "WSB_DIR=$dir WSB_TARBALL=$TARBALL" 2>&1) || { echo "$out"; echo "update failed"; return 1; }
  echo "$out" | tail -n 6
  after=$(local_files) || return 1
  [ "$before" = "$after" ] || { echo "local files changed"; rc=1; }
  grep -qF "Updated wsb: 0.4.0 -> $(as_tester "/src/wsb --version")." <<<"$out" || { echo "no version line"; rc=1; }
  grep -q 'rclone config' <<<"$out" && { echo "first-time steps shown on update"; rc=1; }
  # v0.4.0 shipped a different profiles.yaml.
  as_tester "cd $dir && ls profiles.yaml.bak-* && cmp profiles.yaml /src/profiles.yaml" || { echo "profiles.yaml not backed up and replaced"; rc=1; }
  grep -q 'NOTE: profiles.yaml has changed' <<<"$out" || { echo "no profiles.yaml note"; rc=1; }
  out=$(get_sh "WSB_DIR=$dir WSB_TARBALL=$TARBALL" 2>&1) || { echo "$out"; echo "second update failed"; rc=1; }
  grep -q NOTE <<<"$out" && { echo "unexpected note on an unchanged profiles.yaml: $out"; rc=1; }
  [ "$(as_tester "ls $dir | grep -c '^profiles.yaml.bak-'")" = 1 ] || { echo "expected exactly one backup"; rc=1; }
  as_tester "rm -rf $dir"
  return "$rc"
}

# An old git clone is updated in place: .git stays, an edited profiles.yaml is saved, no git needed.
scenario_get_sh_migrates_git_clone() {
  local out dir="$HOME_DIR/wsb-git" rc=0
  as_tester "mkdir -p $dir/.git && echo 'ref: refs/heads/master' >$dir/.git/HEAD && cd $dir &&
    cp /src/profiles.yaml . && echo '# local edit' >>profiles.yaml && cp /src/config.conf.example config.conf" || return 1
  out=$(get_sh "WSB_DIR=$dir WSB_TARBALL=$TARBALL" 2>&1) || { echo "$out"; echo "get.sh failed"; return 1; }
  echo "$out" | grep -A2 NOTE
  as_tester "test -f $dir/.git/HEAD" || { echo ".git removed"; rc=1; }
  as_tester "cd $dir && grep -qx '# local edit' profiles.yaml.bak-* && cmp profiles.yaml /src/profiles.yaml" || { echo "edited profiles.yaml not saved"; rc=1; }
  grep -q 'move your changes into profiles.d/' <<<"$out" || { echo "no profiles.d note"; rc=1; }
  grep -q 'was a git clone' <<<"$out" || { echo "no git clone note"; rc=1; }
  as_tester "rm -rf $dir"
  return "$rc"
}

# wsb update downloads get.sh of the release from raw.githubusercontent.com and runs it for its
# own directory. A curl shim serves the local get.sh for that URL (the tag is not released) and
# WSB_TARBALL is passed through; everything else, including the latest tag, is real.
scenario_wsb_update() {
  local out rc=0
  docker exec -i -u tester "$APP" sh -c "mkdir -p $HOME_DIR/shim && cat >$HOME_DIR/shim/curl && chmod +x $HOME_DIR/shim/curl" <<EOF || return 1
#!/bin/sh
echo "\$*" >>$HOME_DIR/curl.log
case "\$4" in https://raw.githubusercontent.com/*) cp /src/get.sh "\$3"; exit ;; esac
exec /usr/bin/curl "\$@"
EOF
  update() { docker exec -u tester -w "$GET_DIR" "$APP" bash -lc "PATH=$HOME_DIR/shim:\$PATH WSB_TARBALL=$TARBALL ./wsb update $1" 2>&1; }
  out=$(update "--version v9.9.9") || { echo "$out"; echo "wsb update --version failed"; rc=1; }
  as_tester "grep -qF 'https://raw.githubusercontent.com/raqso/www-serwer-backup-script/v9.9.9/get.sh' $HOME_DIR/curl.log" || { echo "wrong get.sh URL"; rc=1; }
  grep -qF "Installed wsb v9.9.9 into $GET_DIR." <<<"$out" || { echo "WSB_VERSION/WSB_DIR not passed: $out"; rc=1; }
  grep -q 'Updated wsb: ' <<<"$out" || { echo "no version line: $out"; rc=1; }
  # Without --version: the latest release tag, from the real GitHub redirect.
  out=$(update "") || { echo "$out"; echo "wsb update failed"; rc=1; }
  as_tester "grep -qE 'https://raw.githubusercontent.com/raqso/www-serwer-backup-script/v[0-9]+\.[0-9.]+/get.sh' $HOME_DIR/curl.log" || { echo "latest tag not used"; rc=1; }
  out=$(update "--version 1.0") && { echo "wsb update accepted a bad tag"; rc=1; }
  grep -q 'not a release tag' <<<"$out" || { echo "no bad tag message: $out"; rc=1; }
  as_tester "rm -r $HOME_DIR/shim $HOME_DIR/curl.log"
  return "$rc"
}

# write_config [extra lines]: the valid test config; extra lines override its values.
write_config() {
  as_tester "cat > config.conf <<EOF
DIRECTORY_TO_BACKUP='$WWW_DIR'
LOCAL_BACKUPS_PATH='$LOCAL_REPO'
RCLONE_REMOTE_NAME='$CLOUD_REPO'
DB_HOST='$DB'
DB_NAME='$DB_NAME'
DB_USER='$DB_USER'
DB_PASS='$DB_PASS'
${1:-}
EOF"
}

# Minimal environment, like cron. Runs ./wsb directly, so it also checks the exec bit.
run_backup() { as_tester "env -i HOME=$HOME_DIR PATH=${TEST_PATH:-/usr/bin:/bin} ./wsb backup $*"; }

# expect_backup_failure <grep -E pattern>: wsb backup (without -v) must fail with the pattern on stderr.
expect_backup_failure() {
  local err
  if err=$(run_backup "2>&1 >/dev/null"); then
    echo "wsb backup succeeded, expected failure"
    return 1
  fi
  echo "stderr: $err"
  grep -qE "$1" <<<"$err" || { echo "stderr does not match: $1"; return 1; }
}

# Checksums of every file in the local and cloud repositories.
repos_fingerprint() { as_tester "cd $HOME_DIR && find backups cloud -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum"; }

list_logs() { as_tester "ls logs 2>/dev/null"; }

# new_log <list_logs output from before>: the log files written since then.
new_log() { comm -13 <(echo "$1") <(list_logs) | sed 's|^|logs/|'; }

# maintenance_ran <log>: forget --prune and check ran exactly once in that run.
maintenance_ran() {
  local step count
  for step in forget check; do
    count=$(as_tester "grep -c \"profile 'maintenance': starting '$step'\" $1")
    [ "$count" = 1 ] || { echo "$step ran $count times in $1, expected 1"; return 1; }
  done
}

snapshot_ids() { as_tester "$RESTIC -r $1 snapshots --json" | grep -o '"id":"[^"]*"' | sort; }

scenario_backup() {
  write_config || return 1
  run_backup --verbose || return 1
  as_tester "$RESTIC -r $LOCAL_REPO snapshots --tag db --json | grep -q '\"id\"'" || { echo "no db snapshot"; return 1; }
  as_tester "$RESTIC -r $LOCAL_REPO snapshots --tag www --json | grep -q '\"id\"'" || { echo "no www snapshot"; return 1; }
}

# Re-running the installer (e.g. to update the tools) must keep the key and the filled-in config,
# and skip the tools that are already at the latest version.
scenario_reinstall_keeps_files_skips_current_tools() {
  local before after out
  before=$(as_tester "sha256sum password-file config.conf $HOME_DIR/bin/*") || return 1
  out=$(install_as_tester) || { echo "$out"; return 1; }
  after=$(as_tester "sha256sum password-file config.conf $HOME_DIR/bin/*") || return 1
  [ "$before" = "$after" ] || { echo "password-file, config.conf or ~/bin changed"; return 1; }
  [ "$(grep -c 'is already installed and up to date' <<<"$out")" = 3 ] || { echo "expected 3 tools to be skipped: $out"; return 1; }
  local count
  count=$(as_tester "grep -cxF 'export PATH=\$HOME/bin:\$PATH' ~/.bashrc")
  [ "$count" = 1 ] || { echo "PATH line found $count times in ~/.bashrc, expected 1"; return 1; }
}

scenario_cloud_copy_is_valid_repo() {
  as_tester "$RESTIC -r $CLOUD_REPO snapshots" || return 1
  as_tester "$RESTIC -r $CLOUD_REPO check"
}

scenario_restore_from_cloud() {
  local restored="/tmp/restore$WWW_DIR"
  as_tester "$RESTIC -r $CLOUD_REPO restore latest --tag www --target /tmp/restore" || return 1
  as_tester "diff -r -x cache -x log -x tmp -x '*_default.jpg' $WWW_DIR $restored" || return 1
  local p
  for p in cache log tmp img/tmp img/p/1/photo_default.jpg; do
    as_tester "test ! -e $restored/$p" || { echo "excluded path restored: $p"; return 1; }
  done

  db_root -e "CREATE DATABASE restored" || return 1
  as_tester "$RESTIC -r $CLOUD_REPO dump latest --tag db database_dump.sql" | db_root restored || return 1
  local src dst
  src=$(db_root -N -e "SELECT COUNT(*) FROM $DB_NAME.posts") || return 1
  dst=$(db_root -N -e "SELECT COUNT(*) FROM restored.posts") || return 1
  echo "rows: source=$src restored=$dst"
  [ "$src" = "$dst" ] && [ "$src" -gt 0 ]
}

# Losing the local repo must not create a new one that 'rclone sync' would push over the cloud history.
scenario_missing_local_repo_keeps_cloud_history() {
  local before_files before_ids after_ids
  before_files=$(repos_fingerprint | grep ' cloud/') || return 1
  before_ids=$(snapshot_ids "$CLOUD_REPO") || return 1
  as_tester "rm -rf $LOCAL_REPO" || return 1

  expect_backup_failure "rclone copy \"$CLOUD_REPO\" \"$LOCAL_REPO\"" || return 1
  as_tester "test ! -e $LOCAL_REPO" || { echo "local repo was created"; return 1; }
  [ "$(repos_fingerprint | grep ' cloud/')" = "$before_files" ] || { echo "cloud copy changed"; return 1; }

  # If the destination can't be checked (here: unknown remote), abort instead of initializing.
  write_config "RCLONE_REMOTE_NAME='nosuchremote:backups'" || return 1
  expect_backup_failure "Could not check nosuchremote:backups" || { write_config; return 1; }
  write_config || return 1
  as_tester "test ! -e $LOCAL_REPO" || { echo "local repo was created"; return 1; }

  log "Restoring the local repo with the suggested command"
  as_tester "$HOME_DIR/bin/rclone copy '$CLOUD_REPO' '$LOCAL_REPO'" || return 1
  run_backup || return 1
  after_ids=$(snapshot_ids "$CLOUD_REPO") || return 1
  [ -z "$(comm -23 <(echo "$before_ids") <(echo "$after_ids"))" ] || { echo "old snapshots missing in cloud"; return 1; }
  local added
  added=$(comm -13 <(echo "$before_ids") <(echo "$after_ids") | wc -l)
  echo "snapshots in cloud: before=$(grep -c . <<<"$before_ids") after=$(grep -c . <<<"$after_ids")"
  [ "$added" -ge 1 ] || { echo "no new snapshot in cloud"; return 1; }
}

# A remote root would be wiped by 'rclone sync'; a bare name is a local folder, so nothing gets uploaded.
scenario_invalid_remote_name_rejected() {
  local before rc=0 value
  before=$(repos_fingerprint) || return 1
  for value in gdrive gdrive: gdrive:/ "" /; do
    log "RCLONE_REMOTE_NAME='$value'"
    write_config "RCLONE_REMOTE_NAME='$value'" || return 1
    expect_backup_failure "RCLONE_REMOTE_NAME (must be|is not set)" || rc=1
  done
  as_tester "test ! -e gdrive" || { echo "local 'gdrive' folder created"; rc=1; }
  [ "$(repos_fingerprint)" = "$before" ] || { echo "repositories changed"; rc=1; }
  write_config || return 1
  return "$rc"
}

scenario_invalid_config_rejected() {
  local rc=0 var logs_before
  logs_before=$(list_logs)
  for var in DIRECTORY_TO_BACKUP LOCAL_BACKUPS_PATH DB_NAME DB_USER; do
    write_config "$var=''" || return 1
    expect_backup_failure "$var is not set" || rc=1
  done
  write_config "DIRECTORY_TO_BACKUP='/nonexistent'" || return 1
  expect_backup_failure "DIRECTORY_TO_BACKUP does not exist" || rc=1
  write_config "LOCAL_BACKUPS_PATH='backups'" || return 1
  expect_backup_failure "LOCAL_BACKUPS_PATH must be an absolute path" || rc=1
  as_tester "mv config.conf config.conf.bak" || return 1
  expect_backup_failure "No configuration file" || rc=1
  as_tester "mv config.conf.bak config.conf" || return 1
  write_config || return 1
  # Runs started within the same second must not share (and truncate) a log file.
  [ "$(new_log "$logs_before" | grep -c .)" = 7 ] || { echo "expected 7 new log files"; rc=1; }
  return "$rc"
}

scenario_unknown_argument_rejected() {
  local out rc
  out=$(run_backup "--bogus 2>&1")
  rc=$?
  [ "$rc" != 0 ] || { echo "expected a non-zero exit code: $out"; return 1; }
  grep -q 'invalid option: --bogus' <<<"$out" || { echo "unknown argument not named: $out"; return 1; }
  # Not piped into 'grep -q': it may exit before the output ends and fail the run with SIGPIPE (pipefail).
  grep -q 'Usage:' <<<"$(run_backup "--help")" || { echo "--help shows no usage"; return 1; }
}

# backup.sh and installation.sh are deprecated shims to wsb, kept for existing cron entries.
scenario_deprecated_shims() {
  local out
  out=$(as_tester "env -i HOME=$HOME_DIR PATH=/usr/bin:/bin ./backup.sh -v") || { echo "./backup.sh -v failed"; return 1; }
  grep -q 'Backup completed successfully!' <<<"$out" || { echo "./backup.sh -v shows no output: $out"; return 1; }
  as_tester "env -i HOME=$HOME_DIR PATH=/usr/bin:/bin ./backup.sh --bogus 2>/dev/null" && { echo "./backup.sh --bogus succeeded"; return 1; }
  grep -q 'wsb install' <<<"$(as_tester "./installation.sh --help")" || { echo "./installation.sh --help is not the wsb install help"; return 1; }
}

# Cron mails any output, so a successful run without -v must be silent; the output goes to logs/.
scenario_quiet_success_logs_privately() {
  local out err
  as_tester "test ! -e /tmp/rclone.log" || { echo "/tmp/rclone.log exists before the run"; return 1; }
  local logs_before
  logs_before=$(list_logs)
  out=$(run_backup "2>$HOME_DIR/stderr") || { echo "wsb backup failed"; as_tester "cat $HOME_DIR/stderr"; return 1; }
  err=$(as_tester "cat $HOME_DIR/stderr; rm $HOME_DIR/stderr")
  [ -z "$out$err" ] || { echo "expected no output, got stdout: '$out' stderr: '$err'"; return 1; }
  local log
  log=$(new_log "$logs_before")
  echo "log: $log"
  [ "$(grep -c . <<<"$log")" = 1 ] || { echo "expected one new log file"; return 1; }
  [ "$(as_tester "stat -c %a logs $log")" = $'700\n600' ] || { echo "logs/ must be 700 and the log 600"; return 1; }
  as_tester "grep -q 'snapshot .* saved' $log" || { echo "log has no restic output"; return 1; }
  # forget --prune and check cover the whole repository, so they run once per run, not per profile.
  maintenance_ran "$log" || return 1
  # Retention must keep the snapshots this run just made (the latest db and www ones).
  local id saved snapshots
  saved=$(as_tester "sed -n 's/.*snapshot \([0-9a-f]*\) saved.*/\1/p' $log")
  [ "$(grep -c . <<<"$saved")" = 2 ] || { echo "expected 2 new snapshots in the log, got: $saved"; return 1; }
  snapshots=$(as_tester "$RESTIC -r $LOCAL_REPO snapshots --json") || return 1
  for id in $saved; do
    grep -q "\"short_id\":\"$id\"" <<<"$snapshots" || { echo "snapshot $id of this run was removed"; return 1; }
  done
  as_tester "test ! -e /tmp/rclone.log" || { echo "/tmp/rclone.log was written"; return 1; }
}

# The commands resticprofile generates for the steps of wsb backup: default compression, and
# the repository-wide forget --prune without a --path filter.
scenario_generated_commands() {
  local out
  out=$(as_tester "set -a && . ./config.conf && export PATH=$HOME_DIR/bin:\$PATH && {
    resticprofile --dry-run --name database backup && resticprofile --dry-run --name www backup &&
    resticprofile --dry-run --name maintenance forget && resticprofile --dry-run --name maintenance check; } 2>&1") || return 1
  echo "$out" | grep -E 'dry-run|relative'
  local rc=0
  grep -q 'relative "path"' <<<"$out" && { echo "resticprofile warns about relative paths"; rc=1; }
  grep 'dry-run: .*/restic ' <<<"$out" | grep -v -- '--compression=auto' && { echo "restic command without --compression=auto"; rc=1; }
  [ "$(grep -c 'dry-run: .*/restic forget .*--prune' <<<"$out")" = 1 ] || { echo "expected one forget --prune"; rc=1; }
  [ "$(grep -c 'dry-run: .*/restic check ' <<<"$out")" = 1 ] || { echo "expected one check"; rc=1; }
  grep 'dry-run: .*/restic forget' <<<"$out" | grep -E -- '--path|--tag' && { echo "forget must cover all snapshots"; rc=1; }
  return "$rc"
}

scenario_rclone_bwlimit() {
  local log logs_before before value rc=0
  write_config "RCLONE_BWLIMIT=''" || return 1
  run_backup || { echo "backup with empty RCLONE_BWLIMIT failed"; rc=1; }
  write_config "RCLONE_BWLIMIT='10M'" || return 1
  logs_before=$(list_logs)
  run_backup || { echo "backup with RCLONE_BWLIMIT=10M failed"; rc=1; }
  log=$(new_log "$logs_before")
  as_tester "grep 'Starting bandwidth limiter at 10Mi' $log" || { echo "bandwidth limit not applied"; rc=1; }
  # An invalid value is rejected before anything is backed up.
  before=$(repos_fingerprint) || return 1
  for value in bogus '10 M'; do
    write_config "RCLONE_BWLIMIT='$value'" || return 1
    expect_backup_failure "RCLONE_BWLIMIT is not a valid" || rc=1
  done
  [ "$(repos_fingerprint)" = "$before" ] || { echo "repositories changed"; rc=1; }
  write_config || return 1
  return "$rc"
}

# nice applies to the backup commands only, not to the shell that started wsb
# (a process group renice would also slow down whatever that shell runs next).
scenario_low_priority() {
  local out rc=0
  # mysqldump is started by resticprofile like restic, so it shows their priority.
  as_tester "mkdir -p $HOME_DIR/shim && printf '#!/bin/sh\nnice >$HOME_DIR/dump.nice\nexec /usr/bin/mysqldump \"\$@\"\n' >$HOME_DIR/shim/mysqldump && chmod +x $HOME_DIR/shim/mysqldump" || return 1
  out=$(TEST_PATH="$HOME_DIR/shim:/usr/bin:/bin" run_backup "&& nice") || { echo "wsb backup failed"; rc=1; }
  [ "$out" = 0 ] || { echo "calling shell runs at nice '$out', expected 0"; rc=1; }
  out=$(as_tester "cat $HOME_DIR/dump.nice")
  [ "$out" = 15 ] || { echo "mysqldump ran at nice '$out', expected 15"; rc=1; }
  as_tester "rm -r $HOME_DIR/shim $HOME_DIR/dump.nice"
  return "$rc"
}

# Other users of a shared server can read every process command line (ps), so the DB
# password must not be on any. The shim records them all while the dump starts.
scenario_db_password_not_on_command_line() {
  local rc=0
  as_tester "mkdir -p $HOME_DIR/shim && printf '#!/bin/sh\ncat /proc/[0-9]*/cmdline >$HOME_DIR/cmdlines\nexec /usr/bin/mysqldump \"\$@\"\n' >$HOME_DIR/shim/mysqldump && chmod +x $HOME_DIR/shim/mysqldump" || return 1
  TEST_PATH="$HOME_DIR/shim:/usr/bin:/bin" run_backup || { echo "wsb backup failed"; rc=1; }
  as_tester "grep -aq 'shim/mysqldump' $HOME_DIR/cmdlines" || { echo "shim did not record the mysqldump command line"; rc=1; }
  as_tester "grep -aqF '$DB_PASS' $HOME_DIR/cmdlines" && { echo "DB password found on a command line"; rc=1; }
  as_tester "test ! -e mysqldump.cnf" || { echo "mysqldump.cnf left behind"; rc=1; }
  as_tester "rm -r $HOME_DIR/shim $HOME_DIR/cmdlines"
  return "$rc"
}

# Any character in the DB password works: nothing is parsed by a shell or split into words.
# The account's own ~/.my.cnf must not override config.conf.
scenario_db_password_special_characters() {
  local pw=$'a b$HOME;c&d"e\\f`id`g\'h#i' sql_pw rc=0
  undo_special() {
    write_config
    as_tester "rm -f $HOME_DIR/.my.cnf"
    db_root -e "DROP USER IF EXISTS 'special'@'%'"
  }
  sql_pw=${pw//\\/\\\\}
  sql_pw=${sql_pw//\'/\'\'}
  db_root <<<"CREATE USER 'special'@'%' IDENTIFIED BY '$sql_pw';
GRANT SELECT, LOCK TABLES, SHOW VIEW, TRIGGER ON \`$DB_NAME\`.* TO 'special'@'%';" || { undo_special; return 1; }
  write_config "DB_USER='special'" || { undo_special; return 1; }
  # Appended over stdin, so no quoting layer in between; %q makes it a valid bash assignment.
  docker exec -i -u tester -w "$APP_DIR" "$APP" sh -c 'cat >>config.conf' <<<"DB_PASS=$(printf %q "$pw")" || { undo_special; return 1; }
  as_tester "printf '[client]\nuser=nobody\npassword=wrong\n' >$HOME_DIR/.my.cnf" || { undo_special; return 1; }
  run_backup || { echo "wsb backup failed"; rc=1; }
  as_tester "$RESTIC -r $LOCAL_REPO dump latest --tag db database_dump.sql | grep -q 'INSERT INTO .posts.'" ||
    { echo "latest db snapshot has no data"; rc=1; }
  undo_special
  return "$rc"
}

# A failing files backup must not stop the retention policy (or the repository would grow
# until the quota is full) nor the upload of the database backup.
scenario_www_failure_still_maintained_and_uploaded() {
  local db_before db_after err log rc=0
  db_before=$(as_tester "$RESTIC -r $CLOUD_REPO snapshots --tag db --json" | grep -o '"id":"[^"]*"' | sort) || return 1
  as_tester "chmod 000 $WWW_DIR/css" || return 1
  err=$(expect_backup_failure "ERROR: Backup of 'www' failed") || rc=1
  as_tester "chmod 755 $WWW_DIR/css" || return 1
  echo "$err"
  grep -q "ERROR: Backup failed for: www$" <<<"$err" || { echo "no final ERROR line"; rc=1; }
  log=$(sed -n 's/.*(full log: \(.*\)):$/\1/p' <<<"$err" | head -n 1)
  maintenance_ran "$log" || rc=1
  db_after=$(as_tester "$RESTIC -r $CLOUD_REPO snapshots --tag db --json" | grep -o '"id":"[^"]*"' | sort) || return 1
  [ -n "$(comm -13 <(echo "$db_before") <(echo "$db_after"))" ] || { echo "no new db snapshot in cloud"; rc=1; }
  return "$rc"
}

# A damaged local repository must not be mirrored over the copy in the cloud.
scenario_damaged_repo_not_uploaded() {
  local before rc=0
  before=$(repos_fingerprint | grep ' cloud/') || return 1
  # Damage every pack, so it does not matter which ones prune would remove anyway.
  as_tester "cp -a $LOCAL_REPO/data $HOME_DIR/data.bak && chmod -R u+w $LOCAL_REPO/data &&
    find $LOCAL_REPO/data -type f -exec truncate -s -10 {} +" || return 1
  expect_backup_failure "ERROR: Not uploading to $CLOUD_REPO" || rc=1
  as_tester "cp -a $HOME_DIR/data.bak/. $LOCAL_REPO/data/ && rm -rf $HOME_DIR/data.bak" || return 1
  [ "$(repos_fingerprint | grep ' cloud/')" = "$before" ] || { echo "cloud copy changed"; rc=1; }
  run_backup || { echo "backup after repairing the repository failed"; rc=1; }
  return "$rc"
}

# A run must not start while another one holds the lock, and must not touch the repositories.
scenario_concurrent_run_rejected() {
  local before
  before=$(repos_fingerprint) || return 1
  docker exec -d -u tester -w "$APP_DIR" "$APP" flock backup.lock sleep 300 || return 1
  local i
  for i in $(seq 20); do
    as_tester "! flock -n backup.lock true" && break
    sleep 0.5
  done
  expect_backup_failure "Another backup is already running" || { as_tester "pkill -u tester -x sleep"; return 1; }
  as_tester "pkill -u tester -x sleep" || return 1
  [ "$(repos_fingerprint)" = "$before" ] || { echo "repositories changed"; return 1; }

  log "Without flock: mkdir fallback"
  as_tester "mkdir -p $HOME_DIR/noflock && ln -sf /usr/bin/* $HOME_DIR/noflock/ && rm $HOME_DIR/noflock/flock" || return 1
  as_tester "mkdir backup.lock.d" || return 1
  TEST_PATH="$HOME_DIR/noflock" expect_backup_failure "lock directory .*backup.lock.d exists" || return 1
  [ "$(repos_fingerprint)" = "$before" ] || { echo "repositories changed"; return 1; }
  as_tester "rmdir backup.lock.d" || return 1
  TEST_PATH="$HOME_DIR/noflock" run_backup || return 1
  as_tester "test ! -e backup.lock.d" || { echo "lock directory left behind"; return 1; }
  run_backup || { echo "backup after the lock was released failed"; return 1; }
}

# A failing database dump must not stop the files backup and the cloud upload, but the run fails.
scenario_db_failure_still_backs_up_files() {
  local www_before db_before www_after db_after err rc=0
  www_before=$(as_tester "$RESTIC -r $CLOUD_REPO snapshots --tag www --json" | grep -o '"id":"[^"]*"' | sort) || return 1
  db_before=$(as_tester "$RESTIC -r $CLOUD_REPO snapshots --tag db --json" | grep -o '"id":"[^"]*"' | sort) || return 1
  write_config "DB_PASS='wrongpass'" || return 1
  err=$(expect_backup_failure "ERROR: Backup of 'database' failed") || rc=1
  echo "$err"
  grep -q "Access denied" <<<"$err" || { echo "stderr has no log tail with the dump error"; rc=1; }
  grep -q "ERROR: Backup failed for: database$" <<<"$err" || { echo "no final ERROR line"; rc=1; }
  write_config || return 1
  www_after=$(as_tester "$RESTIC -r $CLOUD_REPO snapshots --tag www --json" | grep -o '"id":"[^"]*"' | sort) || return 1
  db_after=$(as_tester "$RESTIC -r $CLOUD_REPO snapshots --tag db --json" | grep -o '"id":"[^"]*"' | sort) || return 1
  echo "www snapshots in cloud: before=$(grep -c . <<<"$www_before") after=$(grep -c . <<<"$www_after")"
  [ -n "$(comm -13 <(echo "$www_before") <(echo "$www_after"))" ] || { echo "no new www snapshot in cloud"; rc=1; }
  [ "$db_before" = "$db_after" ] || { echo "db snapshots changed after a failed dump"; rc=1; }
  return "$rc"
}

# run_scenario <function> [known-bug]
# Scenarios run in order and share container state.
# A known-bug scenario that fails is reported as XFAIL and does not fail the run;
# if it passes (XPASS) the run fails, so the marker gets removed with the fix.
run_scenario() {
  log "SCENARIO $1"
  if "$1"; then
    if [ "${2:-}" = known-bug ]; then
      SUMMARY+="XPASS: $1 (bug fixed? remove known-bug marker)"$'\n'
      FAILED=1
    else
      SUMMARY+="PASS: $1"$'\n'
    fi
  elif [ "${2:-}" = known-bug ]; then
    SUMMARY+="XFAIL: $1 (known bug)"$'\n'
  else
    SUMMARY+="FAIL: $1"$'\n'
    FAILED=1
  fi
}

START=$SECONDS
setup || { echo "FAIL: setup"; exit 1; }
run_scenario scenario_first_install_generates_password_file
run_scenario scenario_install_with_wget_only
run_scenario scenario_bad_checksum_not_installed
run_scenario scenario_backup
run_scenario scenario_reinstall_keeps_files_skips_current_tools
run_scenario scenario_get_sh_fresh_install
run_scenario scenario_get_sh_wget_only
run_scenario scenario_get_sh_update_keeps_local_files
run_scenario scenario_get_sh_migrates_git_clone
run_scenario scenario_wsb_update
run_scenario scenario_profiles_d_override
run_scenario scenario_cloud_copy_is_valid_repo
run_scenario scenario_restore_from_cloud
run_scenario scenario_invalid_remote_name_rejected
run_scenario scenario_invalid_config_rejected
run_scenario scenario_missing_local_repo_keeps_cloud_history
run_scenario scenario_unknown_argument_rejected
run_scenario scenario_deprecated_shims
run_scenario scenario_quiet_success_logs_privately
run_scenario scenario_generated_commands
run_scenario scenario_rclone_bwlimit
run_scenario scenario_low_priority
run_scenario scenario_db_password_not_on_command_line
run_scenario scenario_db_password_special_characters
run_scenario scenario_concurrent_run_rejected
run_scenario scenario_db_failure_still_backs_up_files
run_scenario scenario_www_failure_still_maintained_and_uploaded
run_scenario scenario_damaged_repo_not_uploaded
printf '\n%s' "$SUMMARY"
echo "Finished in $((SECONDS - START))s"
exit "$FAILED"
