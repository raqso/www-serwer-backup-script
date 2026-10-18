# wsb update: downloads get.sh of the requested (or latest) release and runs it for the
# directory of this wsb. get.sh does the actual update, so there is one implementation of it;
# WSB_TARBALL in the environment is passed through (tests).

set -euo pipefail

repo=raqso/www-serwer-backup-script
tag="${args[--version]:-}"
[ -n "$tag" ] || tag=$(latest_github_tag "$repo")
if [[ ! $tag =~ ^v[0-9]+(\.[0-9]+)+$ ]]; then
  echo "Error: '${tag:-}' is not a release tag like v0.5.0 (or the latest release could not be found: network problem?)." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
url="https://raw.githubusercontent.com/$repo/$tag/get.sh"
if ! download "$url" "$TMP_DIR/get.sh"; then
  echo "Error: downloading $url failed (no such release, a release without get.sh, or a network problem)." >&2
  exit 1
fi
WSB_DIR="$(cd "$(dirname "$0")" && pwd)" WSB_VERSION="$tag" bash "$TMP_DIR/get.sh"
