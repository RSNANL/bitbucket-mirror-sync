#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

node scripts/validate-config.mjs
node -e 'JSON.parse(require("fs").readFileSync("config/authentication.json", "utf8"))'
node --test test/*.test.mjs
node scripts/scan-secrets.mjs .
bash -n scripts/*.sh
scripts/test-mirror-local.sh
(
  cd worker
  npm test
  if command -v tsc >/dev/null 2>&1; then
    tsc -p jsconfig.json
  else
    echo 'tsc not available; Worker type-check skipped locally.' >&2
  fi
)

echo 'All available local validations passed.'
