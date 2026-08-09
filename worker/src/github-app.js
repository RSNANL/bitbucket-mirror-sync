// @ts-check

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
    throw new Error("GitHub App private key is not a supported PEM private key.");
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
  const clientId = config.dispatch.github_app_client_id;
  const installationId = config.dispatch.github_app_installation_id;
  const privateKey = env.GITHUB_APP_PRIVATE_KEY;
  if (!clientId || !installationId || !privateKey) {
    throw new Error("GitHub App dispatch identity is incomplete.");
  }

  const jwt = await createGitHubAppJwt(clientId, privateKey);
  const repositoryName = config.dispatch.github_repository.split("/")[1];
  const response = await fetchImpl(
    `https://api.github.com/app/installations/${installationId}/access_tokens`,
    {
      method: "POST",
      headers: {
        accept: "application/vnd.github+json",
        authorization: `Bearer ${jwt}`,
        "content-type": "application/json",
        "user-agent": "bitbucket-mirror-dispatch-worker",
        "x-github-api-version": "2022-11-28"
      },
      body: JSON.stringify({
        repositories: [repositoryName],
        permissions: { actions: "write" }
      })
    }
  );
  if (!response.ok) {
    throw new Error(`GitHub App installation token request failed: HTTP ${response.status}.`);
  }
  const body = await response.json();
  if (!body || typeof body.token !== "string" || !body.token) {
    throw new Error("GitHub App installation token response did not contain a token.");
  }
  return body.token;
}
