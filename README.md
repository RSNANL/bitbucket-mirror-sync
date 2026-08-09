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
scripts/
  config-lib.mjs            Mirror configuration validation and derived names.
  mirror.sh                 Generic branches-and-tags mirror runtime.
  test-mirror-local.sh      Local bare-repository integration test.
worker/
  src/                      Webhook authentication and dispatch Worker.
  test/                     Worker behavior tests.
tools/
  Connect-MirrorSession.ps1 Interactive provider authentication.
  Disconnect-MirrorSession.ps1
  Modules/                  Provider and session modules.
  New-Mirror.ps1            Mirror provisioning.
  Test-Mirror.ps1           Resource and dispatch validation.
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
Mirror ID:               roomba-automation
GitHub Environment:      mirror-roomba-automation
Worker secret binding:   WEBHOOK_ROOMBA_AUTOMATION
Webhook route:           /webhooks/roomba-automation
```

## Validation

```bash
scripts/validate-all.sh
```

The suite validates non-secret configuration, scans for secret material, tests branch/tag mirroring and pruning with local repositories, exercises Worker authentication and dispatch behavior, and type-checks Worker source when `tsc` is available.

Local operator prerequisites can be checked without provider authentication:

```powershell
./tools/Test-Prerequisites.ps1 -SkipSessionAuthentication
```

## Provisioning

Provisioning is planning-only unless `-Apply` is explicitly supplied:

```powershell
./tools/New-Mirror.ps1 `
  -MirrorId roomba-automation `
  -BitbucketRepository '<workspace>/<repository>' `
  -GitHubRepository 'RSNANL/roomba-automation-mirror' `
  -WorkerBaseUrl 'https://<worker>.<subdomain>.workers.dev'
```

The script never commits or pushes infrastructure code. See `docs/provisioning.md`.

## Versioning convention

Git is the sole versioning mechanism for the infrastructure. Stable architectural identifiers do not contain release or schema version markers. Version values appear only when they are intrinsic external constraints, such as runtime requirements, dependency references, API headers or Git tags.

## Secret boundary

No provider account token, private key, webhook secret or password belongs in Git. Management account access is interactive and process-scoped. Persistent unattended runtime credentials are deliberately limited to repository- or machine-scoped identities and live only in provider-managed encrypted secret stores.
