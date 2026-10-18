#!/bin/bash
# End-to-end test: real installation.sh + backup.sh in a shared-hosting-like
# Docker setup (non-root user, limited DB privileges, rclone local "cloud").
# Usage: ./tests/e2e.sh   (needs Docker and network access)
# Add a scenario: write a scenario_* function, then add a run_scenario line at the bottom.
# shellcheck disable=SC2317,SC2329 # cleanup and scenario_* are invoked indirectly (trap, run_scenario)

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ID="www-backup-e2e-$$"
NET="$ID-net"
DB="$ID-db"
APP="$ID-app"

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

FAILED=0
SUMMARY=""

cleanup() {
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
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
  # Release binaries downloaded by installation.sh are linux_amd64.
  docker run -d --name "$APP" --network "$NET" --platform linux/amd64 \
    -v "$REPO_DIR:/src:ro" ubuntu:24.04 sleep infinity >/dev/null || return 1

  log "Installing OS packages (as root, like the hosting provider would)"
  docker exec "$APP" bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl ca-certificates bzip2 unzip mariadb-client >/dev/null && useradd -m -s /bin/bash tester \
    && install -d -o tester -g tester $APP_DIR" || return 1

  log "Seeding website directory and copying repo scripts"
  as_tester "
    set -e
    cp /src/installation.sh /src/backup.sh /src/profiles.yaml /src/config.conf.example $APP_DIR/
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
install_as_tester() { docker exec -u tester -w "$APP_DIR" "$APP" bash -lc './installation.sh'; }

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
}

scenario_backup() {
  as_tester "cat > config.conf <<EOF
DIRECTORY_TO_BACKUP='$WWW_DIR'
LOCAL_BACKUPS_PATH='$LOCAL_REPO'
RCLONE_REMOTE_NAME='$CLOUD_REPO'
DB_HOST='$DB'
DB_NAME='$DB_NAME'
DB_USER='$DB_USER'
DB_PASS='$DB_PASS'
EOF" || return 1
  # Minimal environment, like cron.
  as_tester "env -i HOME=$HOME_DIR PATH=/usr/bin:/bin bash backup.sh --verbose" || return 1
  as_tester "$RESTIC -r $LOCAL_REPO snapshots --tag db --json | grep -q '\"id\"'" || { echo "no db snapshot"; return 1; }
  as_tester "$RESTIC -r $LOCAL_REPO snapshots --tag www --json | grep -q '\"id\"'" || { echo "no www snapshot"; return 1; }
}

# Re-running the installer (e.g. to update the tools) must keep the key and the filled-in config.
scenario_reinstall_keeps_password_and_config() {
  local before after
  before=$(as_tester "sha256sum password-file config.conf") || return 1
  install_as_tester || return 1
  after=$(as_tester "sha256sum password-file config.conf") || return 1
  [ "$before" = "$after" ] || { echo "password-file or config.conf changed"; return 1; }
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
run_scenario scenario_backup
run_scenario scenario_reinstall_keeps_password_and_config
run_scenario scenario_cloud_copy_is_valid_repo
run_scenario scenario_restore_from_cloud
printf '\n%s' "$SUMMARY"
echo "Finished in $((SECONDS - START))s"
exit "$FAILED"
