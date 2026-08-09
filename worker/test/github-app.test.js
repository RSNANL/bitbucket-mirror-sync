// @ts-check
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";
import { createGitHubAppJwt, getGitHubInstallationToken } from "../src/github-app.js";

/** @param {ArrayBuffer} data */
function toPem(data) {
  const base64 = Buffer.from(data).toString("base64").match(/.{1,64}/g)?.join("\n");
  const label = "PRIVATE" + " KEY";
  return `-----BEGIN ${label}-----\n${base64}\n-----END ${label}-----\n`;
}

async function privateKeyPem() {
  const keyPair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"]
  );
  return toPem(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey));
}

test("creates an RS256 GitHub App JWT with bounded timestamps", async () => {
  const jwt = await createGitHubAppJwt("Iv23liExampleClientId", await privateKeyPem(), 1_800_000_000);
  const [header, payload, signature] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url").toString()), { alg: "RS256", typ: "JWT" });
  assert.deepEqual(JSON.parse(Buffer.from(payload, "base64url").toString()), {
    iat: 1_799_999_940,
    exp: 1_800_000_540,
    iss: "Iv23liExampleClientId"
  });
  assert.ok(signature.length > 100);
});

test("accepts the PKCS1 PEM format generated for GitHub Apps", async () => {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const pem = privateKey.export({ format: "pem", type: "pkcs1" }).toString();
  const jwt = await createGitHubAppJwt("Iv23liExampleClientId", pem);
  assert.equal(jwt.split(".").length, 3);
});

test("requests a repository- and permission-bounded installation token", async () => {
  let requestedUrl = "";
  /** @type {RequestInit | undefined} */
  let requestedInit;
  const config = {
    dispatch: {
      github_repository: "RSNANL/bitbucket-mirror-sync",
      github_app_client_id: "Iv23liExampleClientId",
      github_app_installation_id: 12345678
    }
  };
  const token = await getGitHubInstallationToken(
    config,
    { GITHUB_APP_PRIVATE_KEY: await privateKeyPem() },
    async (url, init) => {
      requestedUrl = String(url);
      requestedInit = init;
      return Response.json({ token: "installation-token" });
    }
  );
  assert.equal(token, "installation-token");
  assert.equal(requestedUrl, "https://api.github.com/app/installations/12345678/access_tokens");
  assert.match(new Headers(requestedInit?.headers).get("authorization") ?? "", /^Bearer [^.]+\.[^.]+\.[^.]+$/);
  assert.deepEqual(JSON.parse(String(requestedInit?.body)), {
    repositories: ["bitbucket-mirror-sync"],
    permissions: { actions: "write" }
  });
});
