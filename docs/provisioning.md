# Provisioning

## Operator prerequisites

Any operator machine may be used when it has:

- PowerShell 7;
- Git;
- OpenSSH `ssh-keygen`;
- Node.js 22 or newer;
- GitHub CLI;
- a clone of this infrastructure repository;
- access to the provider accounts required for the operation.

No provider account token is a prerequisite. Management authentication is interactive and session-scoped.

Validate only the local toolchain before authentication:

```powershell
./tools/Test-Prerequisites.ps1 -SkipSessionAuthentication
```

Then start a management session:

```powershell
./tools/Connect-MirrorSession.ps1
```

See `authentication.md` for the one-time provider application registrations and the session boundary.

## Worker bootstrap

Before the first mirror is provisioned, create a separate private GitHub App for unattended dispatch. Configure only repository permission `Actions: write` (GitHub adds metadata read access), install it only on `RSNANL/bitbucket-mirror-sync`, and generate one private key.

Run the deployment once without `-Apply` and review the plan:

```powershell
./tools/Deploy-MirrorWorker.ps1 `
  -GitHubAppClientId '<client-id>' `
  -GitHubAppInstallationId <installation-id> `
  -GitHubAppPrivateKeyPath '<downloaded-private-key.pem>'
```

Then apply the same parameters. The deployment uses the active Cloudflare OAuth session directly, stores the public GitHub App identifiers in `config/mirrors.json`, uploads the private key only as encrypted Worker secret `GITHUB_APP_PRIVATE_KEY`, and preserves all existing Worker secrets on later deployments. No Wrangler login or persistent Cloudflare deployment credential is used. After bootstrap, remove the downloaded private-key file once the encrypted binding has been verified.

## New mirror

Run once without `-Apply` and review the plan. With `-Apply`, `New-Mirror.ps1`:

1. verifies that the Bitbucket source exists and the GitHub target does not;
2. generates two unique Ed25519 keypairs in an OS temporary directory;
3. creates an empty private GitHub target repository;
4. registers a read-only Bitbucket deploy key;
5. registers a write-enabled GitHub deploy key;
6. creates the derived GitHub Environment;
7. uploads both private keys to environment secrets through the current GitHub management session;
8. generates a random webhook HMAC secret;
9. stores it as an encrypted Cloudflare Worker secret;
10. creates the Bitbucket `repo:push` webhook;
11. adds the local non-secret mirror entry;
12. removes all local private-key files.

Before creating any provider resource, the script verifies that the generic Worker is deployed and contains its GitHub App machine-identity secret. The script does not commit, push, deploy the Worker or dispatch the mirror workflow.

Example planning call:

```powershell
./tools/New-Mirror.ps1 `
  -MirrorId generic-vacuum-statemachine-blueprint `
  -BitbucketRepository 'rsna_nl/generic-vacuum-statemachine-blueprint' `
  -GitHubRepository 'RSNANL/generic-vacuum-statemachine-blueprint-mirror' `
  -WorkerBaseUrl 'https://<worker>.<subdomain>.workers.dev'
```

`WorkerBaseUrl` is the HTTPS origin only, for example `https://bitbucket-mirror-dispatch.example.workers.dev`; credentials, paths, query strings and fragments are rejected because the webhook path is derived centrally.

After review:

```powershell
./tools/New-Mirror.ps1 @parameters -Apply
```

## Review and activation

First verify the provisioned resources without dispatching a workflow:

```powershell
./tools/Test-Mirror.ps1 -MirrorId generic-vacuum-statemachine-blueprint
```

This verifies the source and private target repositories, managed deploy keys, exact active `repo:push` webhook URL, required GitHub Environment secret names and required Cloudflare secret-binding names. Secret values remain unreadable by design.

Then activate the reviewed configuration in this order:

1. review and commit only the generated non-secret configuration on the feature branch;
2. open a pull request to `main` and let `validate.yml` complete automatically;
3. merge the reviewed change to `main`;
4. update the local `main` checkout;
5. redeploy the Worker from that exact `main` tree without the deleted local GitHub App private-key file;
6. submit and verify a manual generic workflow dispatch;
7. perform a real Bitbucket push test;
8. create and then delete a temporary source branch and tag and verify both are pruned from GitHub.

The generic workflow must be present on the repository default branch before webhook or manual dispatch can succeed. Worker deployment is a management operation and therefore uses the current interactive Cloudflare management session; no Cloudflare deployment token is stored in GitHub Actions.

After the configuration and Worker are active, submit the manual dispatch with:

```powershell
./tools/Test-Mirror.ps1 -MirrorId generic-vacuum-statemachine-blueprint -Dispatch
```

Only after the manual dispatch, webhook-driven push and pruning tests succeed should `scheduled_recovery` be changed to `true`. That configuration change follows the same review and merge path and is followed by another Worker deployment so the deployed snapshot remains aligned with `main`.

The existing `mirror-doser.yml` workflow remains active and scheduled independently during this migration. Do not enable a generic schedule for the doser until its dedicated workflow has been explicitly retired.

## End the management session

```powershell
./tools/Disconnect-MirrorSession.ps1
```

Closing the PowerShell process also removes all local session credentials. A future management session must authenticate again.
