// @ts-check
import assert from "node:assert/strict";
import test from "node:test";
import { createHmacSha256, toHex } from "../src/crypto.js";
import { GitHubAppAuthenticationError } from "../src/github-app.js";
import { createWorker } from "../src/handler.js";

const config = {
  worker: { base_url: null, path_prefix: "/webhooks" },
  dispatch: {
    github_repository: "RSNANL/bitbucket-mirror-sync",
    workflow_file: "mirror.yml",
    ref: "main",
    github_app_client_id: "Iv23liExampleClientId",
    github_app_installation_id: 12345678
  },
  mirrors: [
    {
      id: "generic-vacuum-statemachine-blueprint",
      enabled: true,
      bitbucket_repository: "rsna_nl/generic-vacuum-statemachine-blueprint",
      github_repository: "RSNANL/generic-vacuum-statemachine-blueprint-mirror",
      scheduled_recovery: false
    },
    {
      id: "disabled-mirror",
      enabled: false,
      bitbucket_repository: "rsna_nl/disabled",
      github_repository: "RSNANL/disabled-mirror",
      scheduled_recovery: false
    }
  ]
};

const secret = "unit-test-webhook-secret";
const token = "unit-test-dispatch-token";
const payload = JSON.stringify({
  repository: { full_name: "rsna_nl/generic-vacuum-statemachine-blueprint" }
});

/** @param {string} body */
async function signature(body) {
  const bytes = new TextEncoder().encode(body);
  return `sha256=${toHex(await createHmacSha256(secret, bytes.buffer))}`;
}

/**
 * @param {{ body?: string, event?: string, signatureValue?: string, path?: string, method?: string }} [overrides]
 */
async function request(overrides = {}) {
  const body = overrides.body ?? payload;
  return new Request(
    `https://worker.example${overrides.path ?? "/webhooks/generic-vacuum-statemachine-blueprint"}`,
    {
    method: overrides.method ?? "POST",
    headers: {
      "content-type": "application/json",
      "x-event-key": overrides.event ?? "repo:push",
      "x-hub-signature": overrides.signatureValue ?? await signature(body)
    },
    body: (overrides.method ?? "POST") === "POST" ? body : undefined
    }
  );
}

function env() {
  return {
    WEBHOOK_GENERIC_VACUUM_STATEMACHINE_BLUEPRINT: secret,
    WEBHOOK_DISABLED_MIRROR: secret,
    GITHUB_APP_PRIVATE_KEY: "unit-test-private-key"
  };
}

async function getDispatchToken() {
  return token;
}

test("rejects non-POST methods", async () => {
  const worker = createWorker(config);
  const response = await worker.fetch(await request({ method: "GET" }), env());
  assert.equal(response.status, 405);
});

test("keeps the GitHub App authentication preflight hidden without its ephemeral token", async () => {
  const worker = createWorker(config, { getDispatchToken });
  const preflightRequest = new Request(
    "https://worker.example/_internal/github-app-authentication",
    { method: "POST", headers: { authorization: "Bearer wrong-token" } }
  );
  assert.equal((await worker.fetch(preflightRequest, env())).status, 404);
});

test("verifies the GitHub App authentication without dispatching a workflow", async () => {
  let tokenRequests = 0;
  let dispatchRequests = 0;
  const worker = createWorker(config, {
    getDispatchToken: async () => {
      tokenRequests += 1;
      return token;
    },
    fetchImpl: async () => {
      dispatchRequests += 1;
      return new Response(null, { status: 204 });
    }
  });
  const preflightRequest = new Request(
    "https://worker.example/_internal/github-app-authentication",
    { method: "POST", headers: { authorization: "Bearer ephemeral-token" } }
  );
  const response = await worker.fetch(preflightRequest, {
    ...env(),
    GITHUB_APP_AUTH_PREFLIGHT_TOKEN: "ephemeral-token"
  });
  assert.equal(response.status, 204);
  assert.equal(tokenRequests, 1);
  assert.equal(dispatchRequests, 0);
});

test("returns safe authentication detail from the protected preflight", async () => {
  const worker = createWorker(config, {
    getDispatchToken: async () => {
      throw new GitHubAppAuthenticationError("GitHub App installation token request failed: HTTP 401.");
    }
  });
  const preflightRequest = new Request(
    "https://worker.example/_internal/github-app-authentication",
    { method: "POST", headers: { authorization: "Bearer ephemeral-token" } }
  );
  const originalError = console.error;
  console.error = () => {};
  try {
    const response = await worker.fetch(preflightRequest, {
      ...env(),
      GITHUB_APP_AUTH_PREFLIGHT_TOKEN: "ephemeral-token"
    });
    assert.equal(response.status, 502);
    assert.deepEqual(await response.json(), {
      error: "github_app_authentication_failed",
      detail: "GitHub App installation token request failed: HTTP 401."
    });
  } finally {
    console.error = originalError;
  }
});

test("hides unknown and disabled mirrors", async () => {
  const worker = createWorker(config);
  assert.equal((await worker.fetch(await request({ path: "/webhooks/unknown" }), env())).status, 404);
  assert.equal((await worker.fetch(await request({ path: "/webhooks/disabled-mirror" }), env())).status, 404);
});

test("rejects non-push events", async () => {
  const worker = createWorker(config);
  const response = await worker.fetch(await request({ event: "repo:fork" }), env());
  assert.equal(response.status, 400);
});

test("rejects missing and invalid signatures", async () => {
  const worker = createWorker(config);
  const missing = await request();
  missing.headers.delete("x-hub-signature");
  assert.equal((await worker.fetch(missing, env())).status, 401);
  assert.equal((await worker.fetch(await request({ signatureValue: `sha256=${"0".repeat(64)}` }), env())).status, 401);
});

test("rejects malformed JSON after authenticating the raw body", async () => {
  const worker = createWorker(config);
  const response = await worker.fetch(await request({ body: "{" }), env());
  assert.equal(response.status, 400);
});

test("rejects a payload for a different repository", async () => {
  const worker = createWorker(config);
  const body = JSON.stringify({ repository: { full_name: "rsna_nl/other" } });
  const response = await worker.fetch(await request({ body }), env());
  assert.equal(response.status, 400);
});

test("dispatches the configured workflow for a valid push", async () => {
  let calledUrl = "";
  /** @type {RequestInit | undefined} */
  let calledInit;
  const worker = createWorker(config, {
    getDispatchToken,
    fetchImpl: async (url, init) => {
      calledUrl = String(url);
      calledInit = init;
      return new Response(null, { status: 204 });
    }
  });
  const response = await worker.fetch(await request(), env());
  assert.equal(response.status, 202);
  assert.equal(calledUrl, "https://api.github.com/repos/RSNANL/bitbucket-mirror-sync/actions/workflows/mirror.yml/dispatches");
  assert.equal(calledInit?.method, "POST");
  assert.equal(new Headers(calledInit?.headers).get("authorization"), `Bearer ${token}`);
  assert.deepEqual(JSON.parse(String(calledInit?.body)), {
    ref: "main",
    inputs: { mirror_id: "generic-vacuum-statemachine-blueprint" }
  });
});

test("returns a gateway error when GitHub rejects the dispatch", async () => {
  const worker = createWorker(config, {
    getDispatchToken,
    fetchImpl: async () => new Response("denied", { status: 403 })
  });
  const response = await worker.fetch(await request(), env());
  assert.equal(response.status, 502);
});

test("fails closed when required Worker secrets are absent", async () => {
  const worker = createWorker(config);
  assert.equal((await worker.fetch(await request(), { GITHUB_APP_PRIVATE_KEY: "private-key" })).status, 503);
  assert.equal((await worker.fetch(await request(), {
    WEBHOOK_GENERIC_VACUUM_STATEMACHINE_BLUEPRINT: secret
  })).status, 503);
});
