#!/usr/bin/env bash
# Checks the offline parts of the wsb install download helpers (src/lib/download.sh):
# reading the release tag from curl and wget redirect headers, and checksum verification.
# No network needed.

set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=src/lib/download.sh
. src/lib/download.sh

fail=0
check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: got '$2', want '$3'" >&2
    fail=1
  fi
}

# curl -sI over HTTP/2: lower-case header names, CRLF line ends.
curl_headers=$'HTTP/2 302 \r\ndate: Sun, 18 Oct 2026 17:01:47 GMT\r\nlocation: https://github.com/restic/restic/releases/tag/v0.19.1\r\ncontent-length: 0\r\n\r\n'
check "curl Location header" "$(tag_from_location <<<"$curl_headers")" v0.19.1

# wget -S: indented headers on stderr, plus its own messages.
wget_headers='  HTTP/1.1 302 Found
  Location: https://github.com/creativeprojects/resticprofile/releases/tag/v0.33.1
  Content-Length: 0
0 redirections exceeded.'
check "wget Location header" "$(tag_from_location <<<"$wget_headers")" v0.33.1

check "no redirect" "$(tag_from_location <<<$'HTTP/2 200 \r\ncontent-type: text/html\r\n')" ""

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'restic binary' >"$tmp/restic_0.19.1_linux_arm64.bz2"
hash=$(sha256sum "$tmp/restic_0.19.1_linux_arm64.bz2" 2>/dev/null || shasum -a 256 "$tmp/restic_0.19.1_linux_arm64.bz2")
hash=${hash%% *}
other=0000000000000000000000000000000000000000000000000000000000000000
# PGP clearsigned, like rclone's SHA256SUMS; similar names must not match.
cat >"$tmp/SHA256SUMS" <<EOF
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA1

$other  restic_0.19.1_linux_arm64.bz2.sig
$other  xrestic_0.19.1_linux_arm64.bz2
$hash  restic_0.19.1_linux_arm64.bz2
$other  restic_0.19.1_linux_amd64.bz2
-----BEGIN PGP SIGNATURE-----
iQEzBAEBCAAdFiEE
-----END PGP SIGNATURE-----
EOF
check "sums entry" "$(sums_entry "$tmp/SHA256SUMS" restic_0.19.1_linux_arm64.bz2)" "$hash"
check "sums entry, binary mode" "$(sums_entry <(echo "$hash *a.zip") a.zip)" "$hash"
check "sums entry missing" "$(sums_entry "$tmp/SHA256SUMS" restic_0.19.1_linux_386.bz2)" ""

declare -A deps
for tool in sha256sum shasum; do
  deps[sha256]=$tool
  command -v "$tool" >/dev/null || continue
  check "${deps[sha256]}: matching file accepted" "$(verify_sha256 "$tmp/restic_0.19.1_linux_arm64.bz2" "$tmp/SHA256SUMS" 2>&1 && echo ok)" ok
  cp "$tmp/restic_0.19.1_linux_arm64.bz2" "$tmp/restic_0.19.1_linux_amd64.bz2"
  check "${deps[sha256]}: mismatch rejected" "$(verify_sha256 "$tmp/restic_0.19.1_linux_amd64.bz2" "$tmp/SHA256SUMS" 2>&1 | grep -o 'checksum mismatch')" "checksum mismatch"
  check "${deps[sha256]}: unlisted file rejected" "$(verify_sha256 "$tmp/SHA256SUMS" "$tmp/SHA256SUMS" 2>&1 | grep -o 'not listed')" "not listed"
done

exit "$fail"
