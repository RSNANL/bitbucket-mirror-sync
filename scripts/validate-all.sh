#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

node scripts/validate-config.mjs
node -e 'for (const file of ["config/authentication.json", "config/authentication.schema.json", "config/mirrors.schema.json"]) JSON.parse(require("fs").readFileSync(file, "utf8"))'
node --test test/*.test.mjs
node scripts/scan-secrets.mjs .
bash -n scripts/*.sh
scripts/test-mirror-local.sh
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File scripts/test-powershell-syntax.ps1
  pwsh -NoProfile -Command 'Import-Module ./tools/Modules/Mirror.Session.psm1 -Force; Test-MirrorAuthenticationConfiguration -RequireConfigured'
else
  echo 'pwsh not available; PowerShell syntax and authentication validation skipped locally.' >&2
fi
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
