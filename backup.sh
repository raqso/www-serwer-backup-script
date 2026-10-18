#!/bin/bash

VERBOSE=false

export PATH=$PATH:$HOME/bin

case "$1" in
-v | --verbose) VERBOSE=true ;;
esac

function log() {
  if [ "$VERBOSE" = true ]; then
    echo -e "${1}"
  fi
}

# Errors always go to stderr (cron mails them), regardless of --verbose.
function die() {
  echo "ERROR: ${1}" >&2
  exit 1
}

cd "$(dirname "$0")" || exit 1

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

export DB_USER DB_PASS DB_HOST DB_NAME
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

log "Starting backup process..."
if ! resticprofile --name "full" backup; then
  die "Error during backup with Restic!"
fi

log "Backup completed successfully!"
exit 0
