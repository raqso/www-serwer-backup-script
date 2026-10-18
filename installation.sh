#!/bin/bash
# Installs or updates restic, resticprofile and rclone into ~/bin and creates the initial
# password-file and config.conf next to this script. Safe to run again: existing
# password-file and config.conf are never overwritten.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/bin"
# Make freshly installed tools usable right away in this script (sourcing ~/.bashrc does
# nothing in a non-interactive shell).
export PATH="$BIN_DIR:$PATH"

for cmd in curl bzip2 unzip tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is required but not installed. Ask your hosting provider or install it first." >&2
    exit 1
  fi
done

mkdir -p "$BIN_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Prints the download URL of the latest GitHub release asset of repo $1 matching pattern $2.
latest_release_url() {
  local url
  url=$(curl -fsSL "https://api.github.com/repos/$1/releases/latest" | grep "browser_download_url.*$2" | head -n 1 | cut -d '"' -f 4) || true
  if [ -z "$url" ]; then
    echo "Error: could not get the latest $1 release URL from GitHub (network problem or API rate limit). Try again later." >&2
    exit 1
  fi
  echo "$url"
}

echo
if command -v restic >/dev/null 2>&1; then
  echo "restic is already installed, updating..."
  restic self-update || echo "Warning: restic self-update failed, keeping the current version." >&2
else
  echo "Installing restic..."
  restic_url=$(latest_release_url restic/restic "linux_amd64.bz2")
  curl -fsSL "$restic_url" -o "$TMP_DIR/restic.bz2"
  bzip2 -d "$TMP_DIR/restic.bz2"
  chmod +x "$TMP_DIR/restic"
  mv "$TMP_DIR/restic" "$BIN_DIR/"
  restic version
fi

echo
if command -v resticprofile >/dev/null 2>&1; then
  echo "resticprofile is already installed, updating..."
  resticprofile self-update || echo "Warning: resticprofile self-update failed, keeping the current version." >&2
else
  echo "Installing resticprofile..."
  resticprofile_url=$(latest_release_url creativeprojects/resticprofile "linux_amd64.tar.gz")
  curl -fsSL "$resticprofile_url" -o "$TMP_DIR/resticprofile.tar.gz"
  tar -xzf "$TMP_DIR/resticprofile.tar.gz" -C "$TMP_DIR"
  chmod +x "$TMP_DIR/resticprofile"
  mv "$TMP_DIR/resticprofile" "$BIN_DIR/"
  resticprofile version
fi

echo
if command -v rclone >/dev/null 2>&1; then
  echo "rclone is already installed, updating..."
  rclone self-update || echo "Warning: rclone self-update failed, keeping the current version." >&2
else
  echo "Installing rclone..."
  curl -fsSL https://downloads.rclone.org/rclone-current-linux-amd64.zip -o "$TMP_DIR/rclone.zip"
  unzip -q "$TMP_DIR/rclone.zip" -d "$TMP_DIR"
  mv "$TMP_DIR"/rclone-*-linux-amd64/rclone "$BIN_DIR/"
  rclone version
fi

# shellcheck disable=SC2016 # $HOME and $PATH must expand in .bashrc, not here
path_line='export PATH=$HOME/bin:$PATH'
if ! grep -qxF "$path_line" ~/.bashrc 2>/dev/null; then
  echo "$path_line" >>~/.bashrc
fi

cd "$SCRIPT_DIR"

echo
if [ -s password-file ]; then
  chmod 600 password-file
  echo "Keeping existing ./password-file (it is the key to your existing backups)."
else
  (umask 077 && resticprofile generate --random-key >"$TMP_DIR/password-file")
  if [ ! -s "$TMP_DIR/password-file" ]; then
    echo "Error: generating the repository password failed, ./password-file was not created." >&2
    exit 1
  fi
  mv "$TMP_DIR/password-file" password-file
  chmod 600 password-file
  echo "Generated secure password for the repository in ./password-file. Please keep this safe!"
fi

echo
if [ -e config.conf ]; then
  chmod 600 config.conf
  echo "Keeping existing ./config.conf."
else
  (umask 077 && cp config.conf.example config.conf)
  chmod 600 config.conf
  echo "Created example configuration in ./config.conf, please fill this with your own values"
fi

echo
