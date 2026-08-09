# Architecture

## Source-of-truth boundaries

Bitbucket repositories are authoritative project sources. GitHub repositories created by this infrastructure are disposable mirrors and never contain unique project work.

`config/mirrors.json` is the authoritative non-secret registry of configured mirrors. Technical resource names are derived from the mirror ID and are not independently configurable.

`config/authentication.json` contains only non-secret identifiers required to initiate interactive management authentication. Management access tokens are never configuration.

## Runtime flow

```text
Bitbucket push
  -> repository webhook
  -> Cloudflare Worker
  -> HMAC + repository + event validation
  -> repository-scoped GitHub App installation token
  -> generic GitHub Actions workflow dispatch
  -> temporary GitHub-hosted runner
  -> read-only fetch from Bitbucket
  -> force/prune branches and tags to GitHub mirror
```

The GitHub Actions job consumes one mirror-specific GitHub Environment containing the two repository-scoped SSH private keys. No operator account credential participates in normal mirror runtime.

## Management flow

```text
PowerShell management process
  -> interactive GitHub authorization
  -> interactive Cloudflare authorization
  -> interactive Bitbucket authorization
  -> short-lived process-only session credentials
  -> provision / test / rotate / repair / remove
  -> disconnect or close process
```

A management session cannot silently reuse a locally stored provider account token. The provider remains responsible for its browser login, consent and multi-factor-authentication policy.

## Responsibility boundaries

- Bitbucket owns authoritative source code and history.
- The infrastructure repository owns mirror registration, generic workflow, Worker source and management tooling.
- Cloudflare Worker owns webhook authentication and workflow dispatch.
- A dedicated GitHub App owns the unattended, repository-scoped dispatch identity.
- GitHub Actions owns the transient Git synchronization execution.
- Provider secret stores own persistent repository-scoped runtime secrets.
- The operator owns explicit initiation and approval of every management authentication session.
