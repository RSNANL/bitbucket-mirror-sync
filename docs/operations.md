# Operations

All provider-changing operations require an active management session created with:

```powershell
./tools/Connect-MirrorSession.ps1
```

A new PowerShell process must authenticate again. See `authentication.md`.

## Deploy the Worker

`Deploy-MirrorWorker.ps1` is planning-only unless `-Apply` is supplied. It deploys the current Worker source and mirror configuration directly through the active Cloudflare OAuth session, preserves existing Worker secrets and enables the configured `workers.dev` route.

The first deployment also receives the dedicated dispatch GitHub App client ID, installation ID and downloaded private-key path. The IDs are written to non-secret configuration; the private key is written only to the encrypted `GITHUB_APP_PRIVATE_KEY` Worker binding. Later source/config deployments preserve that binding and do not require the private-key file.

```powershell
./tools/Deploy-MirrorWorker.ps1 @parameters
./tools/Deploy-MirrorWorker.ps1 @parameters -Apply
```

Worker deployment never commits, pushes, provisions a mirror or dispatches a workflow.

## Validate a mirror

`Test-Mirror.ps1` checks provider repositories, managed deploy keys, the active Bitbucket webhook and required GitHub Environment secret names. `-Dispatch` submits the generic mirror workflow. Secret values remain unreadable by design.

## Rotate keys

Rotation is two-phase:

```powershell
./tools/Rotate-MirrorKeys.ps1 -MirrorId <id> -Phase Prepare
# Verify the dispatched workflow succeeds.
./tools/Rotate-MirrorKeys.ps1 -MirrorId <id> -Phase Finalize
```

Prepare adds new public keys before replacing private environment secrets. Finalize removes only superseded managed keys after explicit operational verification.

## Repair

`Repair-Mirror.ps1` recreates a missing disposable GitHub target, ensures the environment exists and prepares replacement keys. `-RepairWebhook` replaces the webhook and HMAC secret together when either side is lost.

## Remove

`Remove-Mirror.ps1` is planning-only unless `-Apply` is supplied. It removes only resources carrying deterministic managed mirror labels, deletes the per-mirror Worker secret and removes the local configuration entry. The Bitbucket source repository is never deleted. The GitHub mirror is deleted only with `-DeleteTargetRepository`.

## Failure handling

A failed webhook does not alter Bitbucket. A failed mirror run can be dispatched again. A missing target can be recreated. Partial provisioning state is stored without secrets under the OS temporary directory and can support cleanup or diagnosis.

End the management session explicitly when provider changes are complete:

```powershell
./tools/Disconnect-MirrorSession.ps1
```
