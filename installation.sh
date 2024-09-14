#!/bin/bash

echo
if command -v restic &>/dev/null; then
  echo "restic is already installed, updating..."
  restic self-update
else
  echo "Installing restic..."
  get_latest_restic_url() {
    curl -s https://api.github.com/repos/restic/restic/releases/latest | grep "browser_download_url.*linux_amd64.bz2" | cut -d '"' -f 4
  }

  restic_url=$(get_latest_restic_url)
  curl -L $restic_url -o restic.bz2
  bzip2 -d restic.bz2
  chmod +x restic
  mkdir -p ~/bin
  mv restic ~/bin/
  echo 'export PATH=$HOME/bin:$PATH' >>~/.bashrc
  source ~/.bashrc
  restic version
fi

echo
if command -v resticprofile &>/dev/null; then
  echo "resticprofile is already installed, updating..."
  resticprofile self-update
else
  echo "Installing resticprofile..."
  get_latest_resticprofile_url() {
    curl -s https://api.github.com/repos/creativeprojects/resticprofile/releases/latest | grep "browser_download_url.*linux_amd64.tar.gz" | head -n 1 | cut -d '"' -f 4
  }

  resticprofile_url=$(get_latest_resticprofile_url)
  curl -L $resticprofile_url -o resticprofile.tar.gz
  tar -xzf resticprofile.tar.gz
  chmod +x resticprofile
  mkdir -p ~/bin
  mv resticprofile ~/bin/
  echo 'export PATH=$HOME/bin:$PATH' >>~/.bashrc
  source ~/.bashrc
  resticprofile version
fi

echo
if command -v rclone &>/dev/null; then
  echo "rclone is already installed, updating..."
  rclone self-update
else
  echo "Installing rclone..."
  curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip
  unzip rclone-current-linux-amd64.zip
  rm rclone-current-linux-amd64.zip
  cd rclone-*-linux-amd64
  mv rclone ~/bin/
  cd ..
  rm -rf rclone-*-linux-amd64
  echo 'export PATH=$HOME/bin:$PATH' >>~/.bashrc
  source ~/.bashrc
  rclone version
fi

echo
resticprofile generate --random-key >./password-file
echo "Generated secure password for the repository in ./password-file. Please keep this safe!"

echo
cp config.conf.example config.conf
echo "Created example configuration in ./config.conf, please fill this with your own values"

echo
