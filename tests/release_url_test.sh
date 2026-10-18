#!/bin/bash
# Checks that installation.sh picks the right release asset URL from both minified and
# pretty-printed GitHub API JSON. No network needed.

set -euo pipefail
cd "$(dirname "$0")/.."

# Load only the parser function, not the whole installer.
eval "$(sed -n '/^extract_asset_url()/,/^}/p' installation.sh)"

base=https://github.com/creativeprojects/resticprofile/releases/download/v0.33.1
want="$base/resticprofile_0.33.1_linux_amd64.tar.gz"
pattern='resticprofile_[0-9.]+_linux_amd64\.tar\.gz'

minified='{"url":"https://api.github.com/repos/creativeprojects/resticprofile/releases/1","assets":[{"url":"https://api.github.com/repos/creativeprojects/resticprofile/releases/assets/1","name":"resticprofile_no_self_update_0.33.1_linux_amd64.tar.gz","browser_download_url":"'"$base"'/resticprofile_no_self_update_0.33.1_linux_amd64.tar.gz"},{"url":"https://api.github.com/repos/creativeprojects/resticprofile/releases/assets/2","browser_download_url":"'"$base"'/resticprofile_0.33.1_linux_arm64.tar.gz"},{"url":"https://api.github.com/repos/creativeprojects/resticprofile/releases/assets/3","browser_download_url":"'"$want"'"}]}'

pretty='{
  "url": "https://api.github.com/repos/creativeprojects/resticprofile/releases/1",
  "assets": [
    {
      "url": "https://api.github.com/repos/creativeprojects/resticprofile/releases/assets/1",
      "browser_download_url": "'"$base"'/resticprofile_no_self_update_0.33.1_linux_amd64.tar.gz"
    },
    {
      "url": "https://api.github.com/repos/creativeprojects/resticprofile/releases/assets/2",
      "browser_download_url": "'"$base"'/resticprofile_0.33.1_linux_arm64.tar.gz"
    },
    {
      "url": "https://api.github.com/repos/creativeprojects/resticprofile/releases/assets/3",
      "browser_download_url": "'"$want"'"
    }
  ]
}'

fail=0
check() {
  local got
  got=$(extract_asset_url "$pattern" <<<"$2")
  if [ "$got" = "$want" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: got '$got', want '$want'" >&2
    fail=1
  fi
}
check minified "$minified"
check pretty "$pretty"
exit "$fail"
