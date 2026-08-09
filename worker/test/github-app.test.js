// @ts-check
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";
import {
  createGitHubAppJwt,
  describeGitHubAppAuthenticationError,
  getGitHubInstallationToken,
  preflightGitHubAppAuthentication
} from "../src/github-app.js";

const config = {
  dispatch: {
    github_repository: "RSNANL/bitbucket-mirror-sync",
    github_app_id: 1234567,
    github_app_installation_id: 12345678
  }
};

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
  const jwt = await createGitHubAppJwt(1234567, await privateKeyPem(), 1_800_000_000);
  const [header, payload, signature] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url").toString()), { alg: "RS256", typ: "JWT" });
  assert.deepEqual(JSON.parse(Buffer.from(payload, "base64url").toString()), {
    iat: 1_799_999_940,
    exp: 1_800_000_540,
    iss: 1234567
  });
  assert.ok(signature.length > 100);
});

test("accepts the PKCS1 PEM format generated for GitHub Apps", async () => {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const pem = privateKey.export({ format: "pem", type: "pkcs1" }).toString();
  const jwt = await createGitHubAppJwt(1234567, pem);
  assert.equal(jwt.split(".").length, 3);
});

test("requests a repository- and permission-bounded installation token", async () => {
  let requestedUrl = "";
  /** @type {RequestInit | undefined} */
  let requestedInit;
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

test("reports a rejected installation token request without provider response data", async () => {
  await assert.rejects(
    getGitHubInstallationToken(
      config,
      { GITHUB_APP_PRIVATE_KEY: await privateKeyPem() },
      async () => Response.json({ message: "secret provider detail" }, { status: 401 })
    ),
    { message: "GitHub App bounded installation token request failed: HTTP 401." }
  );
});

test("reports safe errors for incomplete identity, invalid keys and unusable token responses", async (context) => {
  const cases = [
    {
      name: "incomplete dispatch identity",
      run: () => getGitHubInstallationToken(config, {}, async () => Response.json({})),
      message: "GitHub App dispatch identity is incomplete."
    },
    {
      name: "non-numeric App ID",
      run: () => getGitHubInstallationToken(
        {
          dispatch: {
            ...config.dispatch,
            github_app_id: /** @type {any} */ ("Iv23liExampleClientId")
          }
        },
        { GITHUB_APP_PRIVATE_KEY: "unused-private-key" },
        async () => Response.json({})
      ),
      message: "GitHub App dispatch identity is incomplete."
    },
    {
      name: "invalid private key",
      run: () => getGitHubInstallationToken(
        config,
        { GITHUB_APP_PRIVATE_KEY: "provider-secret" },
        async () => Response.json({})
      ),
      message: "GitHub App private key is not a supported PEM private key."
    },
    {
      name: "provider transport failure",
      run: async () => getGitHubInstallationToken(
        config,
        { GITHUB_APP_PRIVATE_KEY: await privateKeyPem() },
        async () => { throw new Error("provider-secret"); }
      ),
      message: "GitHub App bounded installation token request failed: transport error."
    },
    {
      name: "invalid provider JSON",
      run: async () => getGitHubInstallationToken(
        config,
        { GITHUB_APP_PRIVATE_KEY: await privateKeyPem() },
        async () => new Response("not-json", { status: 201 })
      ),
      message: "GitHub App bounded installation token request response was not valid JSON."
    },
    {
      name: "missing token",
      run: async () => getGitHubInstallationToken(
        config,
        { GITHUB_APP_PRIVATE_KEY: await privateKeyPem() },
        async () => Response.json({ message: "provider-secret" }, { status: 201 })
      ),
      message: "GitHub App bounded installation token request response did not contain a token."
    }
  ];

  for (const testCase of cases) {
    await context.test(testCase.name, async () => {
      await assert.rejects(testCase.run(), { message: testCase.message });
    });
  }
});

function validApp() {
  return { id: config.dispatch.github_app_id };
}

function validInstallation() {
  return {
    id: config.dispatch.github_app_installation_id,
    suspended_at: null,
    permissions: { actions: "write", metadata: "read" }
  };
}

function validBoundedToken() {
  return {
    token: "preflight-installation-token",
    permissions: { actions: "write", metadata: "read" },
    repository_selection: "selected",
    repositories: [{ full_name: config.dispatch.github_repository }]
  };
}

/** @param {Response[]} responses */
async function runPreflight(responses) {
  const requests = [];
  await preflightGitHubAppAuthentication(
    config,
    { GITHUB_APP_PRIVATE_KEY: await privateKeyPem() },
    async (url, init) => {
      requests.push({ url: String(url), init });
      const response = responses.shift();
      assert.ok(response, `Unexpected GitHub request: ${String(url)}`);
      return response;
    }
  );
  assert.equal(responses.length, 0);
  return requests;
}

test("preflights the exact App, installation, repository and bounded token before revoking it", async () => {
  const requests = await runPreflight([
    Response.json(validApp()),
    Response.json(validInstallation()),
    Response.json(validInstallation()),
    Response.json(validBoundedToken(), { status: 201 }),
    new Response(null, { status: 204 })
  ]);

  assert.deepEqual(requests.map((request) => [request.init?.method, request.url]), [
    ["GET", "https://api.github.com/app"],
    ["GET", "https://api.github.com/app/installations/12345678"],
    ["GET", "https://api.github.com/repos/RSNANL/bitbucket-mirror-sync/installation"],
    ["POST", "https://api.github.com/app/installations/12345678/access_tokens"],
    ["DELETE", "https://api.github.com/installation/token"]
  ]);
  assert.deepEqual(JSON.parse(String(requests[3].init?.body)), {
    repositories: ["bitbucket-mirror-sync"],
    permissions: { actions: "write" }
  });
  assert.match(new Headers(requests[0].init?.headers).get("authorization") ?? "", /^Bearer [^.]+\.[^.]+\.[^.]+$/);
  assert.equal(
    new Headers(requests[4].init?.headers).get("authorization"),
    "Bearer preflight-installation-token"
  );
});

test("reports the exact failed GitHub App preflight boundary", async (context) => {
  const cases = [
    {
      name: "JWT identity",
      responses: [Response.json({}, { status: 401 })],
      message: "GitHub App JWT identity verification failed: HTTP 401."
    },
    {
      name: "installation lookup",
      responses: [Response.json(validApp()), Response.json({}, { status: 404 })],
      message: "GitHub App installation lookup failed: HTTP 404."
    },
    {
      name: "repository installation lookup",
      responses: [
        Response.json(validApp()),
        Response.json(validInstallation()),
        Response.json({}, { status: 404 })
      ],
      message: "GitHub App dispatch repository installation lookup failed: HTTP 404."
    },
    {
      name: "bounded token request",
      responses: [
        Response.json(validApp()),
        Response.json(validInstallation()),
        Response.json(validInstallation()),
        Response.json({}, { status: 422 })
      ],
      message: "GitHub App bounded installation token request failed: HTTP 422."
    }
  ];

  for (const testCase of cases) {
    await context.test(testCase.name, async () => {
      await assert.rejects(runPreflight(testCase.responses), { message: testCase.message });
    });
  }
});

test("rejects mismatched, suspended or underprivileged App installation state", async (context) => {
  const cases = [
    {
      name: "mismatched App ID",
      responses: [Response.json({ id: 7654321 })],
      message: "GitHub App JWT identity response did not match the configured App ID."
    },
    {
      name: "mismatched installation identity",
      responses: [
        Response.json(validApp()),
        Response.json({ ...validInstallation(), id: 87654321 })
      ],
      message: "GitHub App installation response did not match the configured identity."
    },
    {
      name: "suspended installation",
      responses: [
        Response.json(validApp()),
        Response.json({ ...validInstallation(), suspended_at: "2026-08-10T12:00:00Z" })
      ],
      message: "GitHub App installation is suspended."
    },
    {
      name: "missing Actions write permission",
      responses: [
        Response.json(validApp()),
        Response.json({ ...validInstallation(), permissions: { actions: "read" } })
      ],
      message: "GitHub App installation does not grant Actions: write."
    },
    {
      name: "different repository installation",
      responses: [
        Response.json(validApp()),
        Response.json(validInstallation()),
        Response.json({ ...validInstallation(), id: 87654321 })
      ],
      message: "GitHub App dispatch repository belongs to a different installation."
    }
  ];

  for (const testCase of cases) {
    await context.test(testCase.name, async () => {
      await assert.rejects(runPreflight(testCase.responses), { message: testCase.message });
    });
  }
});

test("validates the bounded token and still revokes an unusable token", async (context) => {
  const cases = [
    {
      name: "missing Actions write permission",
      token: { ...validBoundedToken(), permissions: { actions: "read" } },
      message: "GitHub App bounded installation token does not grant Actions: write."
    },
    {
      name: "missing dispatch repository",
      token: { ...validBoundedToken(), repositories: [{ full_name: "RSNANL/other" }] },
      message: "GitHub App bounded installation token does not include the dispatch repository."
    }
  ];

  for (const testCase of cases) {
    await context.test(testCase.name, async () => {
      await assert.rejects(runPreflight([
        Response.json(validApp()),
        Response.json(validInstallation()),
        Response.json(validInstallation()),
        Response.json(testCase.token, { status: 201 }),
        new Response(null, { status: 204 })
      ]), { message: testCase.message });
    });
  }
});

test("fails the preflight when its temporary installation token cannot be revoked", async () => {
  await assert.rejects(runPreflight([
    Response.json(validApp()),
    Response.json(validInstallation()),
    Response.json(validInstallation()),
    Response.json(validBoundedToken(), { status: 201 }),
    Response.json({}, { status: 503 })
  ]), { message: "GitHub App preflight token revocation failed: HTTP 503." });
});

test("does not expose unexpected thrown values as authentication details", () => {
  assert.equal(
    describeGitHubAppAuthenticationError(new Error("installation-token-value")),
    "GitHub App installation authentication failed: unexpected error."
  );
});
