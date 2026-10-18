# Download and checksum helpers for wsb install. ${deps[http_client]} (curl or wget) and
# ${deps[sha256]} (sha256sum or shasum) are set by bashly from the install dependencies.
# shellcheck disable=SC2154 # deps is set by the bashly dependency check

# download <url> <file>: fails on HTTP errors and leaves no partial file behind.
download() {
  local rc=0
  if [ "${deps[http_client]##*/}" = curl ]; then
    "${deps[http_client]}" -fsSL -o "$2" "$1" || rc=$?
  else
    "${deps[http_client]}" -q -O "$2" "$1" || rc=$?
  fi
  [ "$rc" = 0 ] || rm -f "$2"
  return "$rc"
}

# latest_github_tag <owner/repo>: tag of the latest release, taken from the redirect of
# https://github.com/<owner/repo>/releases/latest, so the GitHub API (and its rate limit) is
# not used. Prints nothing if there is no redirect.
latest_github_tag() {
  local url="https://github.com/$1/releases/latest"
  if [ "${deps[http_client]##*/}" = curl ]; then
    "${deps[http_client]}" -sI "$url" || true
  else
    # wget prints the headers to stderr and exits non-zero because it may not follow the redirect.
    "${deps[http_client]}" -q -S --max-redirect=0 -O /dev/null "$url" 2>&1 || true
  fi | tag_from_location
}

# tag_from_location: reads HTTP response headers on stdin and prints the release tag the
# Location header points to (.../releases/tag/<tag>).
tag_from_location() {
  awk 'tolower($1) == "location:" { print $2 }' | tr -d '\r' | sed -n 's|.*/releases/tag/||p'
}

# sums_entry <sums file> <file name>: the SHA-256 listed for that file name. Lines that are
# not "<hash>  <name>" (or "<hash> *<name>"), like a PGP signature around them, are ignored.
sums_entry() {
  awk -v f="$2" '($2 == f || $2 == "*" f) && length($1) == 64 { print $1; exit }' "$1"
}

# verify_sha256 <file> <sums file>: fails unless the SHA-256 of the file matches the entry
# for its name in the sums file.
verify_sha256() {
  local name want got
  name=${1##*/}
  want=$(sums_entry "$2" "$name")
  if [ -z "$want" ]; then
    echo "Error: $name is not listed in the checksum file." >&2
    return 1
  fi
  if [ "${deps[sha256]##*/}" = sha256sum ]; then
    got=$("${deps[sha256]}" "$1")
  else
    got=$("${deps[sha256]}" -a 256 "$1")
  fi
  got=${got%% *}
  if [ "$got" != "$want" ]; then
    echo "Error: checksum mismatch for $name (expected $want, got $got)." >&2
    return 1
  fi
}
