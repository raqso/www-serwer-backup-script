# wsb install: installs or updates restic, resticprofile and rclone into ~/bin and creates
# the initial password-file, config.conf and profiles.d/ next to wsb. Safe to run again:
# existing password-file and config.conf are never overwritten.
# curl or wget, sha256sum or shasum, tar, gzip, bzip2 and unzip are checked by bashly
# (dependencies in bashly.yml), and ~/bin is put in front of PATH by initialize.sh.
# Every download is checked against the SHA-256 file of its release before it reaches ~/bin.

# Strict mode for the installer only. The arguments are already parsed and nothing but
# this command runs after it, so it does not affect the rest of wsb.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/bin"

fail() {
  echo "Error: $*" >&2
  exit 1
}

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) fail "unsupported architecture $(uname -m). Only x86_64 (amd64) and aarch64 (arm64) are supported." ;;
esac

mkdir -p "$BIN_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# latest_version <owner/repo>: version (without the leading v) of the latest GitHub release.
latest_version() {
  local tag
  tag=$(latest_github_tag "$1")
  [[ $tag =~ ^v[0-9]+(\.[0-9]+)+$ ]] || fail "could not get the latest $1 release from GitHub (network problem?). Try again later."
  echo "${tag#v}"
}

# is_current <tool> <version>: ~/bin/<tool> exists and reports that version.
is_current() {
  local out
  out=$("$BIN_DIR/$1" version 2>/dev/null) || return 1
  out=${out%%$'\n'*}
  case " $out " in
    *" $2 "* | *" v$2 "*) return 0 ;;
  esac
  return 1
}

# get_verified <url> <sums url>: downloads <url> into TMP_DIR (under its own name) and checks
# it against the checksum file at <sums url>. Exits on any failure.
get_verified() {
  local file="$TMP_DIR/${1##*/}"
  download "$1" "$file" || fail "downloading $1 failed."
  download "$2" "$TMP_DIR/sums" || fail "downloading $2 failed."
  verify_sha256 "$file" "$TMP_DIR/sums" || fail "${1##*/} does not match $2, not installing it. Nothing in $BIN_DIR was changed."
}

echo
version=$(latest_version restic/restic)
if is_current restic "$version"; then
  echo "restic $version is already installed and up to date."
else
  echo "Installing restic $version..."
  asset="restic_${version}_linux_$ARCH"
  base="https://github.com/restic/restic/releases/download/v$version"
  get_verified "$base/$asset.bz2" "$base/SHA256SUMS"
  bzip2 -d "$TMP_DIR/$asset.bz2"
  chmod +x "$TMP_DIR/$asset"
  mv "$TMP_DIR/$asset" "$BIN_DIR/restic"
  "$BIN_DIR/restic" version
fi

echo
version=$(latest_version creativeprojects/resticprofile)
if is_current resticprofile "$version"; then
  echo "resticprofile $version is already installed and up to date."
else
  echo "Installing resticprofile $version..."
  asset="resticprofile_${version}_linux_$ARCH.tar.gz"
  base="https://github.com/creativeprojects/resticprofile/releases/download/v$version"
  get_verified "$base/$asset" "$base/checksums.txt"
  tar -xzf "$TMP_DIR/$asset" -C "$TMP_DIR" resticprofile
  chmod +x "$TMP_DIR/resticprofile"
  mv "$TMP_DIR/resticprofile" "$BIN_DIR/resticprofile"
  "$BIN_DIR/resticprofile" version
fi

echo
# rclone does not publish its binaries as GitHub release assets; version.txt is "rclone vX.Y.Z".
download https://downloads.rclone.org/version.txt "$TMP_DIR/rclone-version.txt" || true
version=$(sed -n 's/^rclone v//p' "$TMP_DIR/rclone-version.txt" 2>/dev/null) || true
[[ $version =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "could not get the latest rclone version from downloads.rclone.org (network problem?). Try again later."
if is_current rclone "$version"; then
  echo "rclone $version is already installed and up to date."
else
  echo "Installing rclone $version..."
  asset="rclone-v$version-linux-$ARCH"
  base="https://downloads.rclone.org/v$version"
  get_verified "$base/$asset.zip" "$base/SHA256SUMS"
  unzip -q "$TMP_DIR/$asset.zip" -d "$TMP_DIR"
  chmod +x "$TMP_DIR/$asset/rclone"
  mv "$TMP_DIR/$asset/rclone" "$BIN_DIR/rclone"
  "$BIN_DIR/rclone" version
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

# Local overrides of profiles.yaml (see 'includes' there). Not tracked by git, so updates
# never conflict with them.
mkdir -p profiles.d
chmod 700 profiles.d
if [ ! -e profiles.d/README.txt ]; then
  # shellcheck disable=SC2016 # $DIRECTORY_TO_BACKUP is expanded by resticprofile, not here
  printf '%s\n' \
    '# Local changes to profiles.yaml. Every *.yaml file in this directory is read after' \
    '# profiles.yaml, in alphabetical order. Its values replace the ones in profiles.yaml; a list' \
    '# (like exclude) is replaced as a whole, so repeat the entries you want to keep.' \
    '# These files are not tracked by git, so updating wsb never touches them.' \
    '#' \
    '# Example: save the lines below as profiles.d/local.yaml, without the leading "# ".' \
    '#' \
    '# maintenance:' \
    '#   forget:' \
    '#     keep-daily: 14' \
    '# www:' \
    '#   backup:' \
    '#     exclude:' \
    '#       - "$DIRECTORY_TO_BACKUP/cache"' \
    '#       - "$DIRECTORY_TO_BACKUP/var/tmp"' \
    >profiles.d/README.txt
  echo
  echo "Created ./profiles.d/ for local changes to profiles.yaml (see profiles.d/README.txt)."
fi

echo
