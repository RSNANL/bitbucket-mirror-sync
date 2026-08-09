// @ts-check

export class GitHubAppAuthenticationError extends Error {
  /** @param {string} message */
  constructor(message) {
    super(message);
    this.name = "GitHubAppAuthenticationError";
  }
}

const GITHUB_API_BASE_URL = "https://api.github.com";
const GITHUB_API_VERSION = "2022-11-28";
const GITHUB_USER_AGENT = "bitbucket-mirror-dispatch-worker";

/** @param {Uint8Array} bytes */
function base64Url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

/** @param {number} length */
function encodeDerLength(length) {
  if (length < 128) return new Uint8Array([length]);
  const bytes = [];
  for (let remaining = length; remaining > 0; remaining >>>= 8) bytes.unshift(remaining & 0xff);
  return new Uint8Array([0x80 | bytes.length, ...bytes]);
}

/** @param {...Uint8Array} arrays */
function concatenate(...arrays) {
  const result = new Uint8Array(arrays.reduce((length, array) => length + array.length, 0));
  let offset = 0;
  for (const array of arrays) {
    result.set(array, offset);
    offset += array.length;
  }
  return result;
}

/** @param {number} tag @param {Uint8Array} value */
function derValue(tag, value) {
  return concatenate(new Uint8Array([tag]), encodeDerLength(value.length), value);
}

/** @param {string} pem */
function decodePem(pem) {
  const match = pem.trim().match(
    /^-----BEGIN (RSA )?PRIVATE KEY-----([A-Za-z0-9+/=\r\n]+)-----END (RSA )?PRIVATE KEY-----$/
  );
  if (!match || Boolean(match[1]) !== Boolean(match[3])) {
    throw new GitHubAppAuthenticationError("GitHub App private key is not a supported PEM private key.");
  }
  const binary = atob(match[2].replace(/\s/g, ""));
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return { bytes, isPkcs1: Boolean(match[1]) };
}

/** @param {Uint8Array} pkcs1 */
function wrapPkcs1AsPkcs8(pkcs1) {
  const version = new Uint8Array([0x02, 0x01, 0x00]);
  const rsaAlgorithm = new Uint8Array([
    0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
    0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00
  ]);
  return derValue(0x30, concatenate(version, rsaAlgorithm, derValue(0x04, pkcs1)));
}

/**
 * @param {string} clientId
 * @param {string} privateKeyPem
 * @param {number} [nowSeconds]
 */
export async function createGitHubAppJwt(
  clientId,
  privateKeyPem,
  nowSeconds = Math.floor(Date.now() / 1000)
) {
  const decoded = decodePem(privateKeyPem);
  const keyData = decoded.isPkcs1 ? wrapPkcs1AsPkcs8(decoded.bytes) : decoded.bytes;
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    keyData,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const encoder = new TextEncoder();
  const header = base64Url(encoder.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const payload = base64Url(encoder.encode(JSON.stringify({
    iat: nowSeconds - 60,
    exp: nowSeconds + 540,
    iss: clientId
  })));
  const unsignedToken = `${header}.${payload}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    privateKey,
    encoder.encode(unsignedToken)
  );
  return `${unsignedToken}.${base64Url(new Uint8Array(signature))}`;
}

/** @param {string} credential @param {boolean} [hasBody] */
function githubHeaders(credential, hasBody = false) {
  /** @type {Record<string, string>} */
  const headers = {
    accept: "application/vnd.github+json",
    authorization: `Bearer ${credential}`,
    "user-agent": GITHUB_USER_AGENT,
    "x-github-api-version": GITHUB_API_VERSION
  };
  if (hasBody) headers["content-type"] = "application/json";
  return headers;
}

/**
 * @param {typeof fetch} fetchImpl
 * @param {string} url
 * @param {RequestInit} init
 * @param {string} operation
 */
async function requestGitHub(fetchImpl, url, init, operation) {
  let response;
  try {
    response = await fetchImpl(url, init);
  } catch {
    throw new GitHubAppAuthenticationError(`${operation} failed: transport error.`);
  }
  if (!response.ok) {
    throw new GitHubAppAuthenticationError(`${operation} failed: HTTP ${response.status}.`);
  }
  return response;
}

/** @param {Response} response @param {string} operation */
async function readGitHubJson(response, operation) {
  try {
    return await response.json();
  } catch {
    throw new GitHubAppAuthenticationError(`${operation} response was not valid JSON.`);
  }
}

/**
 * @param {{ dispatch: {
 *   github_repository: string,
 *   github_app_client_id: string | null,
 *   github_app_installation_id: number | null
 * } }} config
 * @param {{ GITHUB_APP_PRIVATE_KEY?: string }} env
 */
async function resolveGitHubAppIdentity(config, env) {
  const clientId = config.dispatch.github_app_client_id;
  const installationId = config.dispatch.github_app_installation_id;
  const privateKey = env.GITHUB_APP_PRIVATE_KEY;
  if (!clientId || !installationId || !privateKey) {
    throw new GitHubAppAuthenticationError("GitHub App dispatch identity is incomplete.");
  }

  let jwt;
  try {
    jwt = await createGitHubAppJwt(clientId, privateKey);
  } catch (error) {
    if (error instanceof GitHubAppAuthenticationError) throw error;
    const errorName = error instanceof Error ? error.name : "UnknownError";
    throw new GitHubAppAuthenticationError(`GitHub App JWT creation failed: ${errorName}.`);
  }
  const [repositoryOwner, repositoryName] = config.dispatch.github_repository.split("/");
  return { clientId, installationId, jwt, repositoryOwner, repositoryName };
}

/**
 * @param {number} installationId
 * @param {string} repositoryName
 * @param {string} jwt
 * @param {typeof fetch} fetchImpl
 */
async function requestGitHubInstallationToken(installationId, repositoryName, jwt, fetchImpl) {
  const operation = "GitHub App bounded installation token request";
  const response = await requestGitHub(
    fetchImpl,
    `${GITHUB_API_BASE_URL}/app/installations/${installationId}/access_tokens`,
    {
      method: "POST",
      headers: githubHeaders(jwt, true),
      body: JSON.stringify({
        repositories: [repositoryName],
        permissions: { actions: "write" }
      })
    },
    operation
  );
  const body = await readGitHubJson(response, operation);
  if (!body || typeof body.token !== "string" || !body.token) {
    throw new GitHubAppAuthenticationError(`${operation} response did not contain a token.`);
  }
  return body;
}

/** @param {string} token @param {typeof fetch} fetchImpl */
async function revokeGitHubInstallationToken(token, fetchImpl) {
  await requestGitHub(
    fetchImpl,
    `${GITHUB_API_BASE_URL}/installation/token`,
    { method: "DELETE", headers: githubHeaders(token) },
    "GitHub App preflight token revocation"
  );
}

/**
 * @param {{ dispatch: {
 *   github_repository: string,
 *   github_app_client_id: string | null,
 *   github_app_installation_id: number | null
 * } }} config
 * @param {{ GITHUB_APP_PRIVATE_KEY?: string }} env
 * @param {typeof fetch} fetchImpl
 */
export async function getGitHubInstallationToken(config, env, fetchImpl) {
  const identity = await resolveGitHubAppIdentity(config, env);
  return (await requestGitHubInstallationToken(
    identity.installationId,
    identity.repositoryName,
    identity.jwt,
    fetchImpl
  )).token;
}

/**
 * @param {{ dispatch: {
 *   github_repository: string,
 *   github_app_client_id: string | null,
 *   github_app_installation_id: number | null
 * } }} config
 * @param {{ GITHUB_APP_PRIVATE_KEY?: string }} env
 * @param {typeof fetch} fetchImpl
 */
export async function preflightGitHubAppAuthentication(config, env, fetchImpl) {
  const identity = await resolveGitHubAppIdentity(config, env);
  const appOperation = "GitHub App JWT identity verification";
  const appResponse = await requestGitHub(
    fetchImpl,
    `${GITHUB_API_BASE_URL}/app`,
    { method: "GET", headers: githubHeaders(identity.jwt) },
    appOperation
  );
  const app = await readGitHubJson(appResponse, appOperation);
  if (!app || app.client_id !== identity.clientId) {
    throw new GitHubAppAuthenticationError(
      "GitHub App JWT identity response did not match the configured client ID."
    );
  }

  const installationOperation = "GitHub App installation lookup";
  const installationResponse = await requestGitHub(
    fetchImpl,
    `${GITHUB_API_BASE_URL}/app/installations/${identity.installationId}`,
    { method: "GET", headers: githubHeaders(identity.jwt) },
    installationOperation
  );
  const installation = await readGitHubJson(installationResponse, installationOperation);
  if (
    !installation ||
    installation.id !== identity.installationId
  ) {
    throw new GitHubAppAuthenticationError(
      "GitHub App installation response did not match the configured identity."
    );
  }
  if (installation.suspended_at !== null) {
    throw new GitHubAppAuthenticationError("GitHub App installation is suspended.");
  }
  if (!installation.permissions || installation.permissions.actions !== "write") {
    throw new GitHubAppAuthenticationError(
      "GitHub App installation does not grant Actions: write."
    );
  }

  const repositoryOperation = "GitHub App dispatch repository installation lookup";
  const encodedOwner = encodeURIComponent(identity.repositoryOwner);
  const encodedRepository = encodeURIComponent(identity.repositoryName);
  const repositoryResponse = await requestGitHub(
    fetchImpl,
    `${GITHUB_API_BASE_URL}/repos/${encodedOwner}/${encodedRepository}/installation`,
    { method: "GET", headers: githubHeaders(identity.jwt) },
    repositoryOperation
  );
  const repositoryInstallation = await readGitHubJson(repositoryResponse, repositoryOperation);
  if (!repositoryInstallation || repositoryInstallation.id !== identity.installationId) {
    throw new GitHubAppAuthenticationError(
      "GitHub App dispatch repository belongs to a different installation."
    );
  }

  const tokenResponse = await requestGitHubInstallationToken(
    identity.installationId,
    identity.repositoryName,
    identity.jwt,
    fetchImpl
  );
  try {
    if (!tokenResponse.permissions || tokenResponse.permissions.actions !== "write") {
      throw new GitHubAppAuthenticationError(
        "GitHub App bounded installation token does not grant Actions: write."
      );
    }
    if (
      !Array.isArray(tokenResponse.repositories) ||
      !(/** @type {Array<{ full_name?: string }>} */ (tokenResponse.repositories)).some(
        (repository) => repository?.full_name?.toLowerCase() ===
          config.dispatch.github_repository.toLowerCase()
      )
    ) {
      throw new GitHubAppAuthenticationError(
        "GitHub App bounded installation token does not include the dispatch repository."
      );
    }
  } finally {
    await revokeGitHubInstallationToken(tokenResponse.token, fetchImpl);
  }
}

/** @param {unknown} error */
export function describeGitHubAppAuthenticationError(error) {
  if (error instanceof GitHubAppAuthenticationError) return error.message;
  return "GitHub App installation authentication failed: unexpected error.";
}
