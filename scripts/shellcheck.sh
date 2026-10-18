#!/bin/bash
# Lints all tracked shell files. Single source of truth for the pre-commit hook and CI.

cd "$(git rev-parse --show-toplevel)" || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not found. Install it: 'brew install shellcheck' (macOS) or 'sudo apt-get install shellcheck' (Debian/Ubuntu)." >&2
  exit 1
fi

# All tracked scripts are bash; config.conf.example has no .sh extension so it is listed explicitly.
git ls-files -z -- '*.sh' config.conf.example | xargs -0 shellcheck --shell=bash
