# Operations

All provider-changing operations require an active management session created with:

```powershell
./tools/Connect-MirrorSession.ps1
```

A new PowerShell process must authenticate again. See `authentication.md`.

## Deploy the Worker

`Deploy-MirrorWorker.ps1` is planning-only unless `-Apply` is supplied. It deploys the current Worker source and mirror configuration directly through the active Cloudflare OAuth session, preserves existing Worker secrets and enables the configured `workers.dev` route. After deployment it binds a random short-lived preflight secret and verifies the GitHub App JWT identity, exact installation, dispatch-repository access and installed `Actions: write` permission through separate provider checks. It then requests the same repository- and permission-bounded installation token used by normal dispatch, validates its effective scope and revokes it immediately. The preflight secret is always removed. Deployment fails at the exact unsuccessful authentication boundary; no mirror workflow is dispatched by this check.

The first deployment also receives the dedicated dispatch GitHub App ID, installation ID and downloaded private-key path. The IDs are written to non-secret configuration; the private key is written only to the encrypted `GITHUB_APP_PRIVATE_KEY` Worker binding. Later source/config deployments preserve that binding and do not require the private-key file.

```powershell
./tools/Deploy-MirrorWorker.ps1 @parameters
./tools/Deploy-MirrorWorker.ps1 @parameters -Apply
```

Worker deployment never commits, pushes, provisions a mirror or dispatches a workflow.

## Validate a mirror

`Test-Mirror.ps1` checks the Bitbucket source, private GitHub target, managed deploy keys, exact active Bitbucket `repo:push` webhook URL, required GitHub Environment secret names and required Cloudflare secret-binding names. `-Dispatch` is rejected for a disabled mirror and otherwise submits the generic mirror workflow. Secret values remain unreadable by design and are proven only by a successful dispatch and webhook delivery.

After the configuration and Worker deployment are active, validate the complete webhook-driven ref lifecycle from an existing local checkout of the configured Bitbucket source:

```powershell
./tools/Test-Mirror.ps1 `
  -MirrorId generic-vacuum-statemachine-blueprint `
  -ValidateSync `
  -SourceRepositoryPath 'D:\RSNA\Home Assistant\generic-vacuum-statemachine-blueprint'
```

This mode verifies that the local checkout's `origin` resolves to the configured Bitbucket repository, derives the actual default branch from Bitbucket and works only in a temporary clone. Before creating temporary refs, it confirms that the management GitHub App can read target refs with `Contents: read`. It then creates an empty commit on a unique temporary branch with a lightweight tag, pushes both source refs, verifies both GitHub refs at the exact commit SHA, removes both source refs and verifies that GitHub prunes them. The source checkout and its active branch remain unchanged. Failure handling attempts to remove any temporary Bitbucket refs and the temporary clone before reporting the original failure; success is reported only after the complete synchronization and cleanup sequence passes.

## Validate infrastructure changes

`validate.yml` runs automatically for pull requests to `main` and can also be started manually. It validates configuration, schema syntax, PowerShell and shell syntax, secret scanning, local branch/tag pruning, Worker behavior and Worker type safety. The job has only `contents: read` and does not receive management or mirror runtime credentials.

## Scheduled recovery

`mirror-recovery.yml` runs daily at `03:17 UTC` and remains manually dispatchable. Its matrix includes only entries with `enabled: true` and `scheduled_recovery: true`. It uses the same generic mirror runtime, isolated GitHub Environment and concurrency group as webhook dispatch.

Scheduled recovery is a fallback, not the primary trigger. Leave it disabled for a new mirror until manual dispatch, a real webhook-driven push and branch/tag pruning have all succeeded.

## Rotate keys

Rotation is two-phase:

```powershell
./tools/Rotate-MirrorKeys.ps1 -MirrorId <id> -Phase Prepare
# Verify the dispatched workflow succeeds.
./tools/Rotate-MirrorKeys.ps1 -MirrorId <id> -Phase Finalize
```

Prepare adds new public keys before replacing private environment secrets. Finalize removes only superseded managed keys after explicit operational verification.

## Repair

`Repair-Mirror.ps1` is a provider-changing operation with one high-impact confirmation boundary and supports `-WhatIf`. It recreates a missing disposable GitHub target, ensures the environment exists, prepares replacement keys and dispatches a verification run. `-RepairWebhook` additionally replaces the webhook and HMAC secret together when either side is lost. After a successful run, finalize the prepared key rotation separately.

## Remove

`Remove-Mirror.ps1` is planning-only unless `-Apply` is supplied. It removes only resources carrying deterministic managed mirror labels, deletes the per-mirror Worker secret and removes the local configuration entry. Missing environments, Worker secrets and disposable GitHub targets are tolerated so cleanup can continue after partial external removal. The Bitbucket source repository is never deleted. An existing GitHub mirror is deleted only with `-DeleteTargetRepository`.

## Failure handling

A failed webhook does not alter Bitbucket. A failed mirror run can be dispatched again. A missing target can be recreated. Partial provisioning state is stored without secrets under the OS temporary directory for diagnosis and manual cleanup; provisioning does not claim transactional rollback across three providers.

The Worker rejects a normal browser `GET` with `405 method_not_allowed`; this confirms reachability and is not a health failure.

End the management session explicitly when provider changes are complete:

```powershell
./tools/Disconnect-MirrorSession.ps1
```
