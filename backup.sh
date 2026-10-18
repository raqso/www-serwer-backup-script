#!/bin/bash
# Usage: ./backup.sh [-v|--verbose]
# Without -v a successful run prints nothing (cron sends no mail); the full output
# of every run is kept in logs/. Failures print an ERROR and the end of the log to stderr.

VERBOSE=false
LOG_FILE=""

# Prefer the tools installed by installation.sh over older system-wide ones.
export PATH="$HOME/bin:$PATH"

function usage() {
  echo "Usage: $0 [-v|--verbose] [-h|--help]
  -v, --verbose  show the backup output (it is always written to logs/)
  -h, --help     show this help"
}

for arg in "$@"; do
  case "$arg" in
  -v | --verbose) VERBOSE=true ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: $arg" >&2
    usage >&2
    exit 2
    ;;
  esac
done

function log() {
  [ -n "$LOG_FILE" ] && echo -e "${1}" >>"$LOG_FILE"
  if [ "$VERBOSE" = true ]; then
    echo -e "${1}"
  fi
}

# Errors always go to stderr (cron mails them), regardless of --verbose.
function die() {
  [ -n "$LOG_FILE" ] && echo "ERROR: ${1}" >>"$LOG_FILE"
  echo "ERROR: ${1}" >&2
  exit 1
}

# Runs a command with its output appended to the log (and shown on the terminal with -v).
function run() {
  if [ "$VERBOSE" = true ]; then
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
  fi
  "$@" >>"$LOG_FILE" 2>&1
}

cd "$(dirname "$0")" || exit 1

# Logs and the lock may contain paths and hostnames: keep them private to this user.
umask 077
mkdir -p logs || exit 1

# One backup at a time: a second run (cron or manual) must not touch the repositories
# while restic prune or 'rclone sync' of the first one is still working.
# flock is released by the kernel when the run (and every child it started) ends, so a
# killed run never leaves a stale lock. Without flock, fall back to an atomic mkdir.
if command -v flock >/dev/null 2>&1; then
  exec 9>>backup.lock || exit 1
  flock -n 9 || die "Another backup is already running (lock held on $PWD/backup.lock)."
else
  # ponytail: a killed run leaves the directory behind; it is reported, not removed automatically.
  mkdir backup.lock.d 2>/dev/null || die "Another backup is already running (lock directory $PWD/backup.lock.d exists).
If no backup is running (e.g. a previous run was killed), remove that directory."
  lock_dir=backup.lock.d
fi
# Set only once the lock is ours, so a rejected second run leaves the first one's files alone.
trap 'rm -f mysqldump.cnf; [ -z "$lock_dir" ] || rmdir "$lock_dir"' EXIT

# The PID keeps the names of two runs started in the same second apart.
LOG_FILE="logs/backup-$(date +%Y%m%d-%H%M%S)-$$.log"
: >"$LOG_FILE" || exit 1
find logs -name 'backup-*.log' -mtime +30 -delete

if [ -f config.conf ]; then
  # shellcheck source=config.conf.example
  . ./config.conf
else
  die "No configuration file! Copy config.conf.example to config.conf and fill it in."
fi

for var in DIRECTORY_TO_BACKUP LOCAL_BACKUPS_PATH RCLONE_REMOTE_NAME DB_NAME DB_USER; do
  [ -n "${!var}" ] || die "$var is not set in config.conf."
done

[ -d "$DIRECTORY_TO_BACKUP" ] || die "DIRECTORY_TO_BACKUP does not exist: $DIRECTORY_TO_BACKUP"

case "$LOCAL_BACKUPS_PATH" in
/*) ;;
*) die "LOCAL_BACKUPS_PATH must be an absolute path (starting with /), got: $LOCAL_BACKUPS_PATH" ;;
esac

# The destination is mirrored with 'rclone sync', so everything else in it gets deleted.
# Accept 'remote:folder' or an absolute local path; never a remote root or a bare name
# (rclone would treat 'gdrive' as a local folder and nothing would leave the server).
case "$RCLONE_REMOTE_NAME" in
/*) remote_path="$RCLONE_REMOTE_NAME" ;;
*:*) remote_path="${RCLONE_REMOTE_NAME#*:}" ;;
*) remote_path="" ;;
esac
if [ -z "${remote_path//\//}" ]; then
  die "RCLONE_REMOTE_NAME must be 'remote:folder' (e.g. gdrive:backups/my-site) or an absolute local path, got: '$RCLONE_REMOTE_NAME'.
The folder is mirrored, so files in it that are not part of the backup get deleted; use a dedicated folder, never the remote root."
fi

bwlimit=()
if [ -n "$RCLONE_BWLIMIT" ]; then
  bwlimit=(--bwlimit "$RCLONE_BWLIMIT")
  # Parses the value without touching any remote, so a typo fails before any work is done.
  error=$(rclone "${bwlimit[@]}" version 2>&1 >/dev/null) ||
    die "RCLONE_BWLIMIT is not a valid rclone --bwlimit value (e.g. '10M'): ${error%%$'\n'*}"
fi

# mysqldump reads the credentials from an option file (mode 600 via umask), so they never
# appear on a command line, where other users of the server could see them with ps.
# Option-file values: double-quoted, \ and " escaped, a newline written as \n.
function cnf_value() {
  local value="${1//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value//$'\n'/\\n}"
}
printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "$(cnf_value "$DB_USER")" "$(cnf_value "$DB_PASS")" \
  "$(cnf_value "$DB_HOST")" >mysqldump.cnf || die "Could not write $PWD/mysqldump.cnf."

export DB_NAME
export DIRECTORY_TO_BACKUP LOCAL_BACKUPS_PATH RCLONE_REMOTE_NAME

# resticprofile creates a new empty repository when none exists locally, and the
# following 'rclone sync' would then replace the backup history in the cloud with it.
# So only allow that when the destination has no repository either (first run).
if [ ! -f "$LOCAL_BACKUPS_PATH/config" ]; then
  log "No local repository at $LOCAL_BACKUPS_PATH, checking $RCLONE_REMOTE_NAME..."
  listing=$(rclone lsf "$RCLONE_REMOTE_NAME" --files-only --max-depth 1 2>&1)
  status=$?
  # rclone exit code 3 = directory not found, i.e. nothing there yet.
  if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
    die "Could not check $RCLONE_REMOTE_NAME for an existing repository (rclone exit code $status):
$listing"
  fi
  if [ "$status" -eq 0 ] && grep -qx config <<<"$listing"; then
    die "The local repository $LOCAL_BACKUPS_PATH is missing, but $RCLONE_REMOTE_NAME already contains one.
Not creating a new repository, because syncing it would delete the backup history there.
Restore the local copy first, then run the backup again:
  rclone copy \"$RCLONE_REMOTE_NAME\" \"$LOCAL_BACKUPS_PATH\""
  fi
  log "No repository found, a new one will be created."
fi

# Low CPU priority (nice 15) so the backup gives way to the website; restic, mysqldump and
# rclone inherit it, and Linux derives their disk priority from it. Set per command, so
# the shell that started this script keeps its priority.
low_priority=()
command -v nice >/dev/null 2>&1 && low_priority=(nice -n 15)

failed=""
# step <name> <description> <command...>: a failed step is reported with the end of its
# output and makes the run fail at the end, but the following steps still run.
function step() {
  local name="$1" description="$2" start
  shift 2
  log "$description..."
  start=$(wc -l <"$LOG_FILE")
  run "${low_priority[@]}" "$@" && return 0
  failed+=" $name"
  echo "ERROR: $description failed. Last lines of its output (full log: $PWD/$LOG_FILE):" >&2
  tail -n +"$((start + 1))" "$LOG_FILE" | tail -n 30 >&2
  return 1
}

# A failing database dump must not stop the files backup, and a failing backup must not
# stop the retention policy (otherwise the repository grows until the quota is full).
step database "Backup of 'database'" resticprofile --name database backup
step www "Backup of 'www'" resticprofile --name www backup
step forget "Removing old snapshots" resticprofile --name maintenance forget
# Never mirror a damaged repository over the good copy in the cloud.
if step check "Repository check" resticprofile --name maintenance check; then
  step upload "Upload" rclone sync "$LOCAL_BACKUPS_PATH" "$RCLONE_REMOTE_NAME" --log-level INFO "${bwlimit[@]}"
else
  echo "ERROR: Not uploading to $RCLONE_REMOTE_NAME, so the copy there is not replaced by a damaged repository." | tee -a "$LOG_FILE" >&2
fi
[ -z "$failed" ] || die "Backup failed for:$failed"

log "Backup completed successfully!"
exit 0
