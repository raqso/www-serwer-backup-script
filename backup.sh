#!/bin/bash
cd "$(dirname "$0")"

if [ -f config.conf ];then
  . ./config.conf
else
  echo "No configuration file!"
  exit 1
fi

CURRENT_BACKUP=`date +%F`
TO_REMOVE=`date +%F -d"-$DAYS day"`

if [ -e $BACKUPS_DIRECTORY/$TO_REMOVE.gz ];then
  rm $BACKUPS_DIRECTORY/$TO_REMOVE.gz
  echo "[0] Oldest backup removed..."
fi

tar cpvfP $BACKUPS_DIRECTORY/www.tar $WWW_DIRECTORY
echo "[1] Home directory packed..."

mysqldump $DATABASE -u$USER -p$PASS > $BACKUPS_DIRECTORY/$DATABASE.sql
echo "[2] Database file downloaded..."

env GZIP=-9 tar cfvz $BACKUPS_DIRECTORY/$CURRENT_BACKUP.gz $BACKUPS_DIRECTORY/www.tar $BACKUPS_DIRECTORY/$DATABASE.sql
echo "[3] Database file compressed..."

rm $BACKUPS_DIRECTORY/www.tar $BACKUPS_DIRECTORY/$DATABASE.sql
echo "[3] Files and database packed into one archive..."

./upload.sh -v -r $GDRIVE_DIRECTORY $BACKUPS_DIRECTORY/$CURRENT_BACKUP.gz
echo "[4] Backup file uploaded to Google Drive!"

exit
