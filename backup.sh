#!/bin/bash

VERBOSE=false

case "$1" in
  -v | --verbose ) VERBOSE=true ;;
esac

function log() {

	if [ "$VERBOSE" = true ]; then
		echo -e "${1}"

	fi
}

cd "$(dirname "$0")"

if [ -f config.conf ];then
  . ./config.conf
else
  log "No configuration file!"
  exit 1
fi

CURRENT_BACKUP=`date +%F`
TO_REMOVE=`date +%F -d"-$DAYS day"`

if [ -e $BACKUPS_DIRECTORY/$TO_REMOVE.gz ];then
  rm $BACKUPS_DIRECTORY/$TO_REMOVE.gz
  log "[0] Oldest backup removed..."
fi

tar cp`if [ "$VERBOSE" = true ]; then echo "v"; fi`fP $BACKUPS_DIRECTORY/www.tar $WWW_DIRECTORY
log "[1] Home directory packed..."

mysqldump $DB_NAME -h$DB_HOST -u$DB_USER -p$DB_PASS > $BACKUPS_DIRECTORY/$DB_NAME.sql
log "[2] Database file downloaded..."

env GZIP=-9 tar cf`if [ "$VERBOSE" = true ]; then echo "v"; fi`z $BACKUPS_DIRECTORY/$CURRENT_BACKUP.gz $BACKUPS_DIRECTORY/www.tar $BACKUPS_DIRECTORY/$DB_NAME.sql
log "[3] Database file compressed..."

rm $BACKUPS_DIRECTORY/www.tar $BACKUPS_DIRECTORY/$DB_NAME.sql
log "[3] Files and database packed into one archive..."

./upload.sh -v -r $GDRIVE_DIRECTORY $BACKUPS_DIRECTORY/$CURRENT_BACKUP.gz
log "[4] Backup file uploaded to Google Drive!"

exit
