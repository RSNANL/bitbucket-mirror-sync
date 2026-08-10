# Bitbucket Mirror Sync

Configuration-driven infrastructure for disposable GitHub mirrors of authoritative Bitbucket repositories.

## Responsibilities

- Bitbucket remains the authoritative project source.
- GitHub mirror repositories are disposable targets and never contain unique project work.
- `config/mirrors.json` is the authoritative non-secret mirror registry.
- `config/authentication.json` contains only non-secret identifiers used to initiate management authentication.
- Cloudflare Worker authenticates Bitbucket push webhooks and dispatches the generic GitHub Actions mirror workflow.
- GitHub Actions performs transient Git synchronization with repository-scoped SSH credentials.
- PowerShell 7 tooling provisions, validates, rotates, repairs and removes mirror resources from an interactively authenticated management session.

## Repository layout

```text
.github/workflows/
  validate.yml              Secret-free infrastructure validation.
  mirror.yml                Generic mirror runtime.
  mirror-recovery.yml       Recovery matrix for configured mirrors.
config/
  mirrors.json              Non-secret mirror registry.
  mirrors.schema.json       Mirror configuration contract.
  authentication.json       Non-secret provider identifiers only.
  authentication.schema.json Authentication configuration contract.
scripts/
  config-lib.mjs            Mirror configuration validation and derived names.
  mirror.sh                 Generic branches-and-tags mirror runtime.
  test-mirror-local.sh      Local bare-repository integration test.
  test-powershell-syntax.ps1 PowerShell parser validation.
worker/
  src/                      Webhook authentication and dispatch Worker.
  test/                     Worker behavior tests.
tools/
  Connect-MirrorSession.ps1 Interactive provider authentication.
  Disconnect-MirrorSession.ps1
  Modules/                  Provider and session modules.
  Deploy-MirrorWorker.ps1   Session-scoped Worker deployment and bootstrap.
  New-Mirror.ps1            New and existing-target mirror provisioning.
  Test-Mirror.ps1           Resource, dispatch and mirror sync validation.
  Rotate-MirrorKeys.ps1     Two-phase key rotation.
  Repair-Mirror.ps1         Mirror and credential repair.
  Remove-Mirror.ps1         Managed resource removal.
docs/
  architecture.md
  authentication.md
  security-model.md
  provisioning.md
  operations.md
```

## Management authentication

Every management PowerShell process must authenticate interactively. The tooling starts provider-owned authorization flows for GitHub, Cloudflare and Bitbucket and retains the resulting access tokens only in the current process. Refresh tokens and provider account credentials are never persisted by this repository.

```powershell
./tools/Connect-MirrorSession.ps1
```

End the session explicitly or close PowerShell:

```powershell
./tools/Disconnect-MirrorSession.ps1
```

See `docs/authentication.md` for the provider application registrations and exact session boundary. OAuth callback URIs and requested scopes are implementation contracts and are not operator configuration.

## Derived resource names

Only the mirror ID is configured. Deterministic technical names are derived from it:

```text
Mirror ID:               generic-vacuum-statemachine-blueprint
GitHub Environment:      mirror-generic-vacuum-statemachine-blueprint
Worker secret binding:   WEBHOOK_GENERIC_VACUUM_STATEMACHINE_BLUEPRINT
Webhook route:           /webhooks/generic-vacuum-statemachine-blueprint
```

## Validation

```bash
scripts/validate-all.sh
```

The suite validates non-secret configuration and schema files, scans for secret material, tests branch/tag mirroring and pruning with local repositories, exercises Worker authentication and dispatch behavior, validates PowerShell syntax when `pwsh` is available, and type-checks Worker source when `tsc` is available.

`validate.yml` runs this validation automatically for every pull request targeting `main` and remains manually dispatchable. It does not consume provider or mirror secrets.

Local operator prerequisites can be checked without provider authentication:

```powershell
./tools/Test-Prerequisites.ps1 -SkipSessionAuthentication
```

## Provisioning

The Worker uses a dedicated GitHub App installation as its unattended dispatch identity. The app is installed only on `RSNANL/bitbucket-mirror-sync` and has only `Actions: write` plus mandatory metadata read access. Its App and installation IDs are non-secret configuration; its private key exists only as the encrypted `GITHUB_APP_PRIVATE_KEY` Worker binding.

Bootstrap or update the Worker from the interactive management session before provisioning a mirror:

```powershell
./tools/Deploy-MirrorWorker.ps1 `
  -GitHubAppId <app-id> `
  -GitHubAppInstallationId <installation-id> `
  -GitHubAppPrivateKeyPath '<downloaded-private-key.pem>'
```

The command is planning-only without `-Apply`. Direct Cloudflare API deployment preserves existing encrypted secret bindings and does not require Wrangler or a persistent deployment credential.

Provisioning is planning-only unless `-Apply` is explicitly supplied:

```powershell
./tools/New-Mirror.ps1 `
  -MirrorId generic-vacuum-statemachine-blueprint `
  -BitbucketRepository 'rsna_nl/generic-vacuum-statemachine-blueprint' `
  -GitHubRepository 'RSNANL/generic-vacuum-statemachine-blueprint-mirror' `
  -WorkerBaseUrl 'https://<worker>.<subdomain>.workers.dev'
```

The script never commits or pushes infrastructure code. Existing private mirror targets can be adopted explicitly with `-UseExistingTarget`; their legacy resources remain untouched until the generic cutover is validated. See `docs/provisioning.md`.

The generic recovery workflow runs daily at `03:17 UTC`, but selects only mirrors with both `enabled: true` and `scheduled_recovery: true`. New mirrors remain manual-only until webhook dispatch and pruning have been proven end to end.

## Versioning convention

Git is the sole versioning mechanism for the infrastructure. Stable architectural identifiers do not contain release or schema version markers. Version values appear only when they are intrinsic external constraints, such as runtime requirements, dependency references, API headers or Git tags.

## Secret boundary

No provider account token, private key, webhook secret or password belongs in Git. Management account access is interactive and process-scoped. Persistent unattended runtime credentials are deliberately limited to repository- or machine-scoped identities and live only in provider-managed encrypted secret stores.
