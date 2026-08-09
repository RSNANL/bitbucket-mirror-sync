# Security model

## Management-session authentication

Provider account credentials are never persistent inputs to the infrastructure.

Each management PowerShell process must run `Connect-MirrorSession.ps1`. GitHub, Cloudflare and Bitbucket then perform fresh interactive authorization transactions through their own browser flows. The resulting access tokens are stored only in process-scoped environment variables and are discarded when the process ends or `Disconnect-MirrorSession.ps1` is run.

No management PAT, API token, OAuth refresh token or provider password is committed, written to configuration, stored in a keyring or copied into GitHub or Cloudflare secret storage.

Non-secret OAuth identifiers such as client IDs, account IDs and loopback callback URIs are explicit configuration in `config/authentication.json`.

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

The unattended Worker dispatch identity is a machine credential and must be scoped only to dispatching the generic workflow in this infrastructure repository. It must never reuse a management-session credential.

## Recovery assumptions

A corrupted or malicious GitHub mirror can be deleted and rebuilt from Bitbucket. Losing a private key does not lock the source repository. A compromised key is revoked at the provider and replaced through two-phase rotation.

## Secret scanning

`scripts/scan-secrets.mjs` rejects known private-key and provider-token patterns before review. This is a guardrail, not a replacement for provider secret stores or human review.
