# Www serwer backup script
It could be used to automate the process of making backups of your www files and mysql database.

# What script does?
* Packs selected directory on your server to tar archive,
* Downloads selected mysql database and compress it,
* Archives above into one archive and optionally sends it to Google Drive (using Google Drive API),
* Removes the oldest backup file (on the server and Google Drive) according number of days set in settings.

# What do you need to start using it
* A Linux server with mysql and tar (it should be as default) installed.
* A Google account and a valid Google Drive API key created.

# How to run this?
