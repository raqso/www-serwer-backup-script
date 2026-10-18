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

# Minimal environment, like cron. Runs ./backup.sh directly, so it also checks the exec bit.
run_backup() { as_tester "env -i HOME=$HOME_DIR PATH=${TEST_PATH:-/usr/bin:/bin} ./backup.sh $*"; }

# expect_backup_failure <grep -E pattern>: backup.sh (without -v) must fail with the pattern on stderr.
expect_backup_failure() {
  local err
  if err=$(run_backup "2>&1 >/dev/null"); then
    echo "backup.sh succeeded, expected failure"
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
  [ "$rc" = 2 ] || { echo "expected exit code 2, got $rc: $out"; return 1; }
  grep -q 'Unknown argument: --bogus' <<<"$out" || { echo "unknown argument not named: $out"; return 1; }
  grep -q 'Usage:' <<<"$out" || { echo "no usage: $out"; return 1; }
  # Not piped into 'grep -q': it may exit before the output ends and fail the run with SIGPIPE (pipefail).
  grep -q 'Usage:' <<<"$(run_backup "--help")" || { echo "--help shows no usage"; return 1; }
}

# Cron mails any output, so a successful run without -v must be silent; the output goes to logs/.
scenario_quiet_success_logs_privately() {
  local out err
  as_tester "test ! -e /tmp/rclone.log" || { echo "/tmp/rclone.log exists before the run"; return 1; }
  local logs_before
  logs_before=$(list_logs)
  out=$(run_backup "2>$HOME_DIR/stderr") || { echo "backup.sh failed"; as_tester "cat $HOME_DIR/stderr"; return 1; }
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

# The commands resticprofile generates for the steps of backup.sh: default compression, and
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

# nice applies to the backup commands only, not to the shell that started backup.sh
# (a process group renice would also slow down whatever that shell runs next).
scenario_low_priority() {
  local out rc=0
  # mysqldump is started by resticprofile like restic, so it shows their priority.
  as_tester "mkdir -p $HOME_DIR/shim && printf '#!/bin/sh\nnice >$HOME_DIR/dump.nice\nexec /usr/bin/mysqldump \"\$@\"\n' >$HOME_DIR/shim/mysqldump && chmod +x $HOME_DIR/shim/mysqldump" || return 1
  out=$(TEST_PATH="$HOME_DIR/shim:/usr/bin:/bin" run_backup "&& nice") || { echo "backup.sh failed"; rc=1; }
  [ "$out" = 0 ] || { echo "calling shell runs at nice '$out', expected 0"; rc=1; }
  out=$(as_tester "cat $HOME_DIR/dump.nice")
  [ "$out" = 15 ] || { echo "mysqldump ran at nice '$out', expected 15"; rc=1; }
  as_tester "rm -r $HOME_DIR/shim $HOME_DIR/dump.nice"
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
run_scenario scenario_backup
run_scenario scenario_reinstall_keeps_password_and_config
run_scenario scenario_cloud_copy_is_valid_repo
run_scenario scenario_restore_from_cloud
run_scenario scenario_invalid_remote_name_rejected
run_scenario scenario_invalid_config_rejected
run_scenario scenario_missing_local_repo_keeps_cloud_history
run_scenario scenario_unknown_argument_rejected
run_scenario scenario_quiet_success_logs_privately
run_scenario scenario_generated_commands
run_scenario scenario_rclone_bwlimit
run_scenario scenario_low_priority
run_scenario scenario_concurrent_run_rejected
run_scenario scenario_db_failure_still_backs_up_files
run_scenario scenario_www_failure_still_maintained_and_uploaded
run_scenario scenario_damaged_repo_not_uploaded
printf '\n%s' "$SUMMARY"
echo "Finished in $((SECONDS - START))s"
exit "$FAILED"
