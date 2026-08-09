// @ts-check
import assert from "node:assert/strict";
import test from "node:test";
import { createHmacSha256, toHex } from "../src/crypto.js";
import { createWorker } from "../src/handler.js";

const config = {
  worker: { base_url: null, path_prefix: "/webhooks" },
  dispatch: {
    github_repository: "RSNANL/bitbucket-mirror-sync",
    workflow_file: "mirror.yml",
    ref: "main"
  },
  mirrors: [
    {
      id: "roomba-automation",
      enabled: true,
      bitbucket_repository: "rsna_nl/roomba-automation",
      github_repository: "RSNANL/roomba-automation-mirror",
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
const payload = JSON.stringify({ repository: { full_name: "rsna_nl/roomba-automation" } });

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
  return new Request(`https://worker.example${overrides.path ?? "/webhooks/roomba-automation"}`, {
    method: overrides.method ?? "POST",
    headers: {
      "content-type": "application/json",
      "x-event-key": overrides.event ?? "repo:push",
      "x-hub-signature": overrides.signatureValue ?? await signature(body)
    },
    body: (overrides.method ?? "POST") === "POST" ? body : undefined
  });
}

function env() {
  return {
    WEBHOOK_ROOMBA_AUTOMATION: secret,
    WEBHOOK_DISABLED_MIRROR: secret,
    GITHUB_DISPATCH_TOKEN: token
  };
}

test("rejects non-POST methods", async () => {
  const worker = createWorker(config);
  const response = await worker.fetch(await request({ method: "GET" }), env());
  assert.equal(response.status, 405);
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
    inputs: { mirror_id: "roomba-automation" }
  });
});

test("returns a gateway error when GitHub rejects the dispatch", async () => {
  const worker = createWorker(config, {
    fetchImpl: async () => new Response("denied", { status: 403 })
  });
  const response = await worker.fetch(await request(), env());
  assert.equal(response.status, 502);
});

test("fails closed when required Worker secrets are absent", async () => {
  const worker = createWorker(config);
  assert.equal((await worker.fetch(await request(), { GITHUB_DISPATCH_TOKEN: token })).status, 503);
  assert.equal((await worker.fetch(await request(), { WEBHOOK_ROOMBA_AUTOMATION: secret })).status, 503);
});
