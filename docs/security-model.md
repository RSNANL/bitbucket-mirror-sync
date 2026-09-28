# Security model

## Management-session authentication

Provider account credentials are never persistent inputs to the infrastructure.

Each management PowerShell process must run `Connect-MirrorSession.ps1`. GitHub, Cloudflare and Bitbucket then perform fresh interactive authorization transactions through their own browser flows. The resulting access tokens are stored only in process-scoped environment variables and are discarded when the process ends or `Disconnect-MirrorSession.ps1` is run.

No management PAT, API token, OAuth refresh token or provider password is committed, written to configuration, stored in a keyring or copied into GitHub or Cloudflare secret storage.

## Local Mirror Manager boundary

Mirror Manager binds exclusively to `127.0.0.1` and accepts management API requests only from its exact origin with a random, per-process request token. Its browser responses disable caching, framing, cross-origin resource loading and permissive form targets through explicit security headers.

The request token and provider session state remain in browser memory only. Provider access tokens never enter the browser. The Bitbucket OAuth consumer secret is accepted only through a password input, sent once to the loopback host, used for the authorization-code exchange and cleared from the operation process after use. It is never put in a URL, operation output, browser storage, cookie, file or configuration.

Only predefined actions and action-specific parameters can reach PowerShell. Arbitrary script paths, commands and unknown arguments are rejected. The host permits only one operation at a time, and UI confirmations do not replace the existing script validation and plan/apply boundaries.

Stopping Mirror Manager stops any running operation and clears all session variables from its PowerShell process. Cloudflare revocation remains best-effort when the normal disconnect action is used; forced host shutdown always clears the local credential state.

Only the management GitHub client ID, Cloudflare client and account IDs, and Bitbucket client ID are stored in `config/authentication.json`. Callback URIs and requested scopes are fixed implementation contracts.

The management GitHub App has repository `Administration: write`, `Environments: write`, `Actions: write` and `Contents: read` permissions. Content access is read-only and is used to resolve temporary branch and tag SHAs during explicit synchronization validation; it is not used by the unattended mirror runtime.

## Credential isolation for mirror runtime

Every mirror uses two unique Ed25519 keypairs:

- a Bitbucket repository deploy key, read-only for one source repository;
- a write-enabled GitHub deploy key scoped to one disposable target repository.

The corresponding private keys are stored under fixed names in a mirror-specific GitHub Environment:

```text
BBT_MIRROR_SSH_KEY
GHB_MIRROR_SSH_KEY
```

Every Bitbucket webhook uses a unique random HMAC secret. The same value exists only in the Bitbucket webhook and its derived Cloudflare Worker secret binding.

The Git runtime accepts only the published Ed25519 SSH host keys for `bitbucket.org` and `github.com`. A runtime scan is compared with the reviewed provider fingerprint before either deploy key is used; a missing or changed host key fails the run closed.

## Worker request validation

Worker:

- accepts only `POST` requests on an exact configured route;
- accepts only `repo:push` events;
- verifies `X-Hub-Signature` as HMAC-SHA256 over the unchanged request body;
- compares the digest without data-dependent early exit;
- verifies `payload.repository.full_name` against configuration;
- hides unknown and disabled mirror IDs behind `404`;
- never logs payloads, signatures, tokens or secret values;
- dispatches only the configured workflow and ref.

The unattended Worker dispatch identity is a dedicated GitHub App installed only on this infrastructure repository with `Actions: write` and mandatory metadata read access. The Worker signs a short-lived JWT with the encrypted `GITHUB_APP_PRIVATE_KEY` binding and requests a repository- and permission-bounded installation token for each dispatch. The installation token expires automatically and no personal access token or management-session credential is persisted.

Pull-request validation is deliberately secret-free. It receives only read access to repository contents, so proposed infrastructure code can be tested without exposing provider access tokens, deploy keys, webhook secrets or the dispatch App private key.

## Recovery assumptions

A corrupted or malicious GitHub mirror can be deleted and rebuilt from Bitbucket. Losing a private key does not lock the source repository. A compromised key is revoked at the provider and replaced through two-phase rotation.

## Secret scanning

`scripts/scan-secrets.mjs` rejects known private-key and provider-token patterns before review. This is a guardrail, not a replacement for provider secret stores or human review.
