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

cd "$(dirname "$0")"

if [ -f config.conf ]; then
  . ./config.conf
else
  log "No configuration file!"
  exit 1
fi

export DB_USER DB_PASS DB_HOST DB_NAME
export DIRECTORY_TO_BACKUP LOCAL_BACKUPS_PATH RCLONE_REMOTE_NAME

log "Starting backup process..."
resticprofile --name "full" backup

if [ $? -ne 0 ]; then
  log "Error during backup with Restic!"
  exit 1
fi

log "Backup completed successfully!"
exit 0
