#!/usr/bin/env bash
# Installs or updates wsb without git:
#   (curl -fsSL https://github.com/raqso/www-serwer-backup-script/releases/latest/download/get.sh || wget -qO- https://github.com/raqso/www-serwer-backup-script/releases/latest/download/get.sh) | bash
# Downloads the release source tarball from GitHub, copies the program files into WSB_DIR
# (default ~/www-serwer-backup-script) and runs 'wsb install'. config.conf, password-file,
# profiles.d/ and logs/ are never touched. 'wsb update' downloads this script and runs it.
#
# Environment:
#   WSB_VERSION  release tag to install (e.g. v0.5.0); default: the latest release
#   WSB_DIR      install directory; default: ~/www-serwer-backup-script
#   WSB_TARBALL  tests only: use this local .tar.gz instead of downloading the release
#
# Everything is inside main(), called on the last line: a truncated download runs nothing.

main() {
  set -euo pipefail

  local repo=raqso/www-serwer-backup-script
  local dir="${WSB_DIR:-$HOME/www-serwer-backup-script}"
  local files=(wsb backup.sh installation.sh profiles.yaml config.conf.example README.md LICENSE)

  fail() {
    echo "Error: $*" >&2
    exit 1
  }

  # Minimal copy of download / latest_github_tag from src/lib/download.sh: this script must
  # run on its own, before wsb exists. Keep both in sync.
  if command -v curl >/dev/null 2>&1; then
    HTTP=curl
  elif command -v wget >/dev/null 2>&1; then
    HTTP=wget
  else
    fail "curl or wget is required but neither is installed. Ask your hosting provider or install one first."
  fi
  local tool
  for tool in tar gzip; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required but not installed. Ask your hosting provider or install it first."
  done

  download() {
    local rc=0
    if [ "$HTTP" = curl ]; then
      curl -fsSL -o "$2" "$1" || rc=$?
    else
      wget -q -O "$2" "$1" || rc=$?
    fi
    [ "$rc" = 0 ] || rm -f "$2"
    return "$rc"
  }

  latest_tag() {
    local url="https://github.com/$repo/releases/latest"
    if [ "$HTTP" = curl ]; then
      curl -sI "$url" || true
    else
      wget -q -S --max-redirect=0 -O /dev/null "$url" 2>&1 || true
    fi | awk 'tolower($1) == "location:" { print $2 }' | tr -d '\r' | sed -n 's|.*/releases/tag/||p'
  }

  local tag="${WSB_VERSION:-}"
  if [ -z "$tag" ]; then
    tag=$(latest_tag)
    [ -n "$tag" ] || fail "could not get the latest release from GitHub (network problem?). Try again later."
  fi
  [[ $tag =~ ^v[0-9]+(\.[0-9]+)+$ ]] || fail "'$tag' is not a release tag like v0.5.0."

  # Global, so the EXIT trap still sees it after main returns.
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  if [ -n "${WSB_TARBALL:-}" ]; then
    cp "$WSB_TARBALL" "$TMP_DIR/wsb.tar.gz"
  else
    echo "Downloading wsb $tag..."
    download "https://github.com/$repo/archive/refs/tags/$tag.tar.gz" "$TMP_DIR/wsb.tar.gz" ||
      fail "downloading wsb $tag failed (no such release, or a network problem)."
  fi
  mkdir "$TMP_DIR/src"
  tar -xzf "$TMP_DIR/wsb.tar.gz" -C "$TMP_DIR/src" || fail "the downloaded wsb $tag archive is damaged."
  # GitHub archives have a single top directory.
  local top
  top=$(find "$TMP_DIR/src" -mindepth 1 -maxdepth 1 -type d)
  local f
  for f in "${files[@]}"; do
    [ -f "$top/$f" ] || fail "wsb $tag has no $f (releases before v0.4.0 cannot be installed this way)."
  done

  mkdir -p "$dir"
  local old="" first_time=1
  [ -x "$dir/wsb" ] && old=$("$dir/wsb" --version 2>/dev/null || true)
  [ -e "$dir/config.conf" ] && first_time=0

  # profiles.yaml is replaced by the new version. A copy of the previous one is kept whenever
  # it differs, because it may hold local edits (this script cannot tell them apart from an
  # older shipped version).
  local bak=""
  if [ -f "$dir/profiles.yaml" ] && ! cmp -s "$dir/profiles.yaml" "$top/profiles.yaml"; then
    bak="profiles.yaml.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$dir/profiles.yaml" "$dir/$bak"
  fi

  # Copy under a temporary name, then rename over the old file: a running wsb keeps reading
  # its old copy, and an interrupted copy never leaves a half-written program file.
  for f in "${files[@]}"; do
    cp -p "$top/$f" "$dir/.$f.new"
    mv -f "$dir/.$f.new" "$dir/$f"
  done
  echo "Installed wsb $tag into $dir."

  # stdin is this script when piped into bash; keep it away from the installer.
  "$dir/wsb" install </dev/null

  local new
  new=$("$dir/wsb" --version)
  if [ -n "$bak" ]; then
    echo
    echo "NOTE: profiles.yaml has changed. Your previous one is saved as $dir/$bak."
    echo "If you edited it, move your changes into profiles.d/ (see profiles.d/README.txt), as"
    echo "profiles.yaml is replaced on every update. Otherwise you can delete the copy."
  fi
  if [ -d "$dir/.git" ]; then
    echo
    echo "NOTE: $dir was a git clone. From now on it is updated with './wsb update' (or the"
    echo "same install command), not with git. You can remove $dir/.git."
  fi

  echo
  if [ "$first_time" = 0 ]; then
    echo "Updated wsb: ${old:-unknown} -> $new. Your config.conf, password-file and profiles.d/ were kept."
  else
    echo "Next steps, in $dir:"
    echo "  1. rclone config                     # set up the cloud remote"
    echo "  2. fill in config.conf"
    echo "  3. copy password-file somewhere off this server (without it backups cannot be restored)"
    echo "  4. ./wsb backup -v                   # first backup, to check everything works"
    echo "  5. crontab -e and add, e.g.:  15 3 * * * $dir/wsb backup"
  fi
}

main "$@"
