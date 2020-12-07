# Www serwer backup script
It could be used to automate the process of making backups of your www files and mysql database.

# What script does?
* Packs selected directory on your server to tar archive,
* Downloads selected mysql database and compress it,
* Archives above into one archive and optionally sends it to Google Drive (using Google Drive API),
* Removes the oldest backup file (on the server and Google Drive) according number of days set in settings.

# What do you need to start using it
* A Linux server with mysql and tar (it should be as default) installed.
* A Google account and a valid Google Drive 'Client ID' and 'Secret client key' created.

# How to run this?
1) Remove the '.example' suffix from the 'config.conf.example' and fill up all configuration data.
2) Launch the script:
```
sh backup.sh
```
by default it's not in verbose mode, to enable this add the `-v` flag
```
sh backup.sh -v
```
3) Before sending backup file to google drive, you should be prompt once to auth. Please follow tips from the terminal.


For the actual uploading to Google Drive this script is being used:
https://github.com/labbots/google-drive-upload
