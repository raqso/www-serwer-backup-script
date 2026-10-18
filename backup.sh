#!/bin/bash
# Deprecated: use './wsb backup [-v]'. Kept so existing cron entries keep working; will be removed in v1.0.
exec "$(dirname "$0")/wsb" backup "$@"
