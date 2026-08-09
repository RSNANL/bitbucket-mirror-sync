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

After review:

```powershell
./tools/New-Mirror.ps1 @parameters -Apply
```

## Review and activation

Review and commit only the generated non-secret configuration. The generic workflow must be present on the repository default branch before webhook dispatch can be tested.

Deploy the Worker again after reviewing the generated configuration. Worker deployment is a management operation and therefore uses the current interactive Cloudflare management session; no Cloudflare deployment token is stored in GitHub Actions.

After the configuration and Worker are active, verify provider resources and manually dispatch the mirror workflow:

```powershell
./tools/Test-Mirror.ps1 -MirrorId generic-vacuum-statemachine-blueprint -Dispatch
```

Only after a successful webhook-driven push test and pruning test should scheduled recovery be enabled.

## End the management session

```powershell
./tools/Disconnect-MirrorSession.ps1
```

Closing the PowerShell process also removes all local session credentials. A future management session must authenticate again.
