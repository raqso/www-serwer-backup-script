#!/bin/bash
# Regenerates ./wsb from src/ with Bashly in Docker (no local Ruby needed).
# Commit src/ and wsb together; CI fails when wsb is out of date.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

BASHLY_IMAGE=dannyben/bashly:2.0.0

docker run --rm --user "$(id -u):$(id -g)" --volume "$PWD:/app" "$BASHLY_IMAGE" generate
