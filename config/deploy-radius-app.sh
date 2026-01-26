#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

log() {
  echo "==> $*"
}

require_cmd rad

APP_BICEP="${APP_BICEP:-apps/todolist/deploy/todolist.bicep}"
PARAMS=("${@:-}")

log "Deploying app: $APP_BICEP"
if [[ ${#PARAMS[@]} -gt 0 ]]; then
  rad deploy "$APP_BICEP" "${PARAMS[@]}"
else
  rad deploy "$APP_BICEP"
fi
