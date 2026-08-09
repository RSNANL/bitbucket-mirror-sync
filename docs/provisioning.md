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

The script does not commit, push, deploy the Worker or dispatch the mirror workflow.

Example planning call:

```powershell
./tools/New-Mirror.ps1 `
  -MirrorId roomba-automation `
  -BitbucketRepository '<workspace>/<repository>' `
  -GitHubRepository 'RSNANL/roomba-automation-mirror' `
  -WorkerBaseUrl 'https://<worker>.<subdomain>.workers.dev'
```

After review:

```powershell
./tools/New-Mirror.ps1 @parameters -Apply
```

## Review and activation

Review and commit only the generated non-secret configuration. The generic workflow must be present on the repository default branch before webhook dispatch can be tested.

Worker deployment is a management operation and therefore uses the current interactive Cloudflare management session; no Cloudflare deployment token is stored in GitHub Actions.

After the configuration and Worker are active, verify provider resources and manually dispatch the mirror workflow:

```powershell
./tools/Test-Mirror.ps1 -MirrorId roomba-automation -Dispatch
```

Only after a successful webhook-driven push test and pruning test should scheduled recovery be enabled.

## End the management session

```powershell
./tools/Disconnect-MirrorSession.ps1
```

Closing the PowerShell process also removes all local session credentials. A future management session must authenticate again.
