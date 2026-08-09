# Management authentication

## Session boundary

Every management operation starts from an explicitly authenticated PowerShell session. Provider account credentials are never persisted by this repository or its tooling.

`Connect-MirrorSession.ps1` performs three interactive provider authorizations and keeps the resulting short-lived access tokens only in process-scoped environment variables. Closing PowerShell or running `Disconnect-MirrorSession.ps1` removes the local session credentials. Refresh tokens are never retained or used for silent reauthentication.

A new PowerShell process therefore requires a new interactive authorization.

Provider browser sessions remain provider-owned. The tooling always starts a new authorization transaction, but the provider decides whether an already authenticated browser session requires password or multi-factor authentication again.

## GitHub

Management access uses a GitHub App user access token obtained through Device Flow.

The GitHub App must:

- have Device Flow enabled;
- keep expiring user access tokens enabled;
- have repository `Administration: write`, `Environments: write` and `Actions: write` permissions;
- be installed on the `RSNANL` account with access to all repositories, so newly created mirror repositories are immediately within the app installation boundary.

The app installation is a provider-side authorization boundary, not a stored operator credential. Only the GitHub App client ID is stored in `config/authentication.json`. Device Flow does not require a client secret. The returned refresh token is deliberately discarded. The access token is exposed to GitHub CLI only as the process-scoped `GH_TOKEN` variable.

Persistent `gh auth login` credentials are forbidden for this workflow. `Test-Prerequisites.ps1` rejects a GitHub CLI keyring login so that management cannot silently fall back to a stored account token.

## Cloudflare

Management access uses Authorization Code with PKCE against a private Cloudflare OAuth client.

The OAuth client is created once under the intended Cloudflare account and remains private. It must:

- use grant type `authorization_code` only;
- use response type `code`;
- use token endpoint authentication method `none`;
- use PKCE `S256`;
- allow the configured loopback redirect URI;
- be limited to the intended Cloudflare account;
- request only `Workers Scripts Write`.

Only the client ID, account ID and loopback redirect URI are stored in `config/authentication.json`. No Cloudflare API token or OAuth client secret is used by management tooling. The access token exists only in the current PowerShell process. Disconnect performs a best-effort call to Cloudflare's OAuth revoke endpoint before clearing the local token.

## Bitbucket

Management access uses the OAuth 2.0 Authorization Code flow from a workspace OAuth consumer.

The consumer is created once in the Bitbucket workspace that owns the managed source repositories. Its callback URL must equal the configured loopback redirect URI and it must request only:

- `repository`;
- `repository:admin`;
- `webhook`.

Bitbucket requires the OAuth consumer secret when the authorization code is exchanged. The operator retrieves that provider-held value and enters it through a secure prompt during every management session. The tooling never writes it to configuration, environment variables, a keyring or Git. The returned access token is retained only in the PowerShell process. The refresh token is discarded; when the access token expires a new interactive authorization is required.

## Persistent operational secrets

Management credentials are separate from the narrowly scoped machine credentials required for unattended mirroring. The following operational secrets are intentionally persistent:

- one read-only Bitbucket deploy key per source repository;
- one write-enabled GitHub deploy key per disposable mirror repository;
- one unique webhook HMAC secret per mirror;
- the machine identity required by the webhook Worker to dispatch the generic mirror workflow.

These values exist only in provider-managed encrypted secret stores and never grant general access to the operator's provider accounts.
