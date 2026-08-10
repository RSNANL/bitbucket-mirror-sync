# Management authentication

## Session boundary

Every management operation starts from an explicitly authenticated PowerShell session. Provider account credentials are never persisted by this repository or its tooling.

`Connect-MirrorSession.ps1` performs three interactive provider authorizations and keeps the resulting short-lived access tokens only in process-scoped environment variables. Closing PowerShell or running `Disconnect-MirrorSession.ps1` removes the local session credentials. Refresh tokens are never retained or used for silent reauthentication.

Mirror Manager starts each provider authorization independently from the local UI. GitHub's device code is shown in the Activity output. Cloudflare and Bitbucket return through their fixed loopback callbacks; their completion pages attempt to close automatically after a successful exchange. Provider browser restrictions may still require the operator to close a completed window manually.

Disconnect also attempts to revoke the Cloudflare access token. GitHub and Bitbucket access tokens are removed locally and then expire according to the provider response; disconnect does not claim immediate provider-side revocation for those two tokens.

A new PowerShell process therefore requires a new interactive authorization.

Provider browser sessions remain provider-owned. The tooling always starts a new authorization transaction, but the provider decides whether an already authenticated browser session requires password or multi-factor authentication again.

## Authentication configuration

`config/authentication.json` contains only installation-specific, non-secret provider identifiers:

- GitHub App client ID;
- Cloudflare OAuth client ID and account ID;
- Bitbucket OAuth client ID.

Provider callback URIs and requested OAuth scopes are implementation contracts and are deliberately not user-configurable. Changing them requires a code change and review rather than an operator configuration edit.

The authentication configuration and all PowerShell sources are validated in pull requests. Unknown provider or field names, non-string client IDs and malformed Cloudflare account IDs are rejected before management tooling is used.

## GitHub

Management access uses a GitHub App user access token obtained through Device Flow.

The GitHub App must:

- have Device Flow enabled;
- keep expiring user access tokens enabled;
- have repository `Administration: write`, `Environments: write`, `Actions: write` and `Contents: read` permissions;
- be installed on the `RSNANL` account with access to all repositories, so newly created mirror repositories are immediately within the app installation boundary.

`Contents: read` is used only to resolve temporary branch and tag refs during synchronization validation. After this permission is added or changed, accept the updated installation permission and start a new management session so its user access token receives the effective scope.

The app installation is a provider-side authorization boundary, not a stored operator credential. Only the GitHub App client ID is stored in `config/authentication.json`. Device Flow does not require a client secret. The returned refresh token is deliberately discarded. The access token is exposed to GitHub CLI only as the process-scoped `GH_TOKEN` variable.

Persistent `gh auth login` credentials are forbidden for this workflow. `Test-Prerequisites.ps1` rejects a GitHub CLI keyring login so that management cannot silently fall back to a stored account token.

## Cloudflare

Management access uses Authorization Code with PKCE against a private Cloudflare OAuth client.

The OAuth client is created once under the intended Cloudflare account and remains private. It must:

- use grant type `authorization_code` only;
- use response type `code`;
- use token endpoint authentication method `none`;
- use PKCE `S256`;
- allow `http://127.0.0.1:53682/callback`;
- be limited to the intended Cloudflare account;
- allow `Workers Scripts Read` (`workers-scripts.read`) and `Workers Scripts Write` (`workers-scripts.write`).

The callback URI and requested scopes are fixed by the management implementation. Only the client ID and account ID are stored in `config/authentication.json`.

Cloudflare authentication is validated in two distinct layers. Session establishment validates the issued OAuth access token against Cloudflare's OAuth `userinfo` endpoint. Workers API capability is validated separately through `Test-CloudflareAuthentication` / `Test-Prerequisites.ps1`. This separation prevents an OAuth-client or token problem from being conflated with a Workers API permission mapping problem.

No Cloudflare API token or OAuth client secret is used by management tooling. The access token exists only in the current PowerShell process. Disconnect performs a best-effort call to Cloudflare's OAuth revoke endpoint before clearing the local token.

## Bitbucket

Management access uses the OAuth 2.0 Authorization Code flow from a workspace OAuth client.

The client is created once in the Bitbucket workspace that owns the managed source repositories. Its callback URL must be `http://127.0.0.1:53683/callback` and it must request only:

- `repository`;
- `repository:admin`;
- `webhook`.

The callback URI is fixed by the management implementation and is not user-configurable.

Bitbucket requires the OAuth client secret when the authorization code is exchanged. The operator retrieves that provider-held value and enters it through a secure PowerShell prompt or the Mirror Manager password field during every management session. The tooling never writes it to configuration, environment variables, browser storage, a keyring or Git. The returned access token is retained only in the PowerShell process. The refresh token is discarded; when the access token expires a new interactive authorization is required.

## Persistent operational secrets

Management credentials are separate from the narrowly scoped machine credentials required for unattended mirroring. The following operational secrets are intentionally persistent:

- one read-only Bitbucket deploy key per source repository;
- one write-enabled GitHub deploy key per disposable mirror repository;
- one unique webhook HMAC secret per mirror;
- one private key for the repository-scoped GitHub App used by the webhook Worker.

These values exist only in provider-managed encrypted secret stores and never grant general access to the operator's provider accounts.

The dispatch GitHub App is separate from the management GitHub App. It is installed only on `RSNANL/bitbucket-mirror-sync`, has only `Actions: write` plus mandatory metadata read access, and does not use Device Flow or a user access token. Its numeric App ID and installation ID are non-secret values in `config/mirrors.json`; the App ID is the JWT issuer and is distinct from the alphanumeric OAuth client ID. Its private key is stored only as the Cloudflare Worker secret `GITHUB_APP_PRIVATE_KEY`.
