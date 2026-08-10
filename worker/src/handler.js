// @ts-check
import { verifyBitbucketSignature } from "./crypto.js";
import {
  describeGitHubAppAuthenticationError,
  getGitHubInstallationToken,
  preflightGitHubAppAuthentication
} from "./github-app.js";

const GITHUB_APP_AUTH_PREFLIGHT_PATH = "/_internal/github-app-authentication";

/**
 * @typedef {{
 *   id: string,
 *   enabled: boolean,
 *   bitbucket_repository: string,
 *   github_repository: string,
 *   scheduled_recovery: boolean
 * }} Mirror
 *
 * @typedef {{
 *   worker: { base_url: string | null, path_prefix: string },
 *   dispatch: {
 *     github_repository: string,
 *     workflow_file: string,
 *     ref: string,
 *     github_app_id: number | null,
 *     github_app_installation_id: number | null
 *   },
 *   mirrors: Mirror[]
 * }} MirrorConfig
 *
 * @typedef {{
 *   GITHUB_APP_PRIVATE_KEY?: string,
 *   GITHUB_APP_AUTH_PREFLIGHT_TOKEN?: string,
 *   [key: string]: string | undefined
 * }} WorkerEnv
 */

/** @param {string} mirrorId */
export function deriveWebhookSecretBinding(mirrorId) {
  return `WEBHOOK_${mirrorId.replaceAll("-", "_").toUpperCase()}`;
}

/** @param {string} repository */
function encodeRepositoryPath(repository) {
  return repository.split("/").map(encodeURIComponent).join("/");
}

/** @param {unknown} value */
function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/**
 * @param {MirrorConfig} config
 * @returns {Map<string, Mirror>}
 */
function buildMirrorIndex(config) {
  if (!Array.isArray(config.mirrors)) {
    throw new Error("Invalid mirror configuration.");
  }
  const index = new Map();
  for (const mirror of config.mirrors) {
    if (index.has(mirror.id)) throw new Error(`Duplicate mirror id: ${mirror.id}.`);
    index.set(mirror.id, mirror);
  }
  return index;
}

/**
 * @param {string} pathname
 * @param {string} prefix
 */
function parseMirrorId(pathname, prefix) {
  if (!pathname.startsWith(`${prefix}/`)) return null;
  const suffix = pathname.slice(prefix.length + 1);
  if (!suffix || suffix.includes("/")) return null;
  return suffix;
}

/**
 * @param {object} body
 * @param {number} status
 */
function jsonResponse(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store"
    }
  });
}

/**
 * @param {MirrorConfig} config
 * @param {{
 *   fetchImpl?: typeof fetch,
 *   getDispatchToken?: typeof getGitHubInstallationToken,
 *   preflightDispatchIdentity?: typeof preflightGitHubAppAuthentication
 * }} [options]
 */
export function createWorker(config, options = {}) {
  const mirrorIndex = buildMirrorIndex(config);
  const fetchImpl = options.fetchImpl ?? fetch;
  const getDispatchToken = options.getDispatchToken ?? getGitHubInstallationToken;
  const preflightDispatchIdentity = options.preflightDispatchIdentity ??
    preflightGitHubAppAuthentication;

  return {
    /**
     * @param {Request} request
     * @param {WorkerEnv} env
     */
    async fetch(request, env) {
      if (request.method !== "POST") {
        return jsonResponse({ error: "method_not_allowed" }, 405);
      }

      const url = new URL(request.url);
      if (url.pathname === GITHUB_APP_AUTH_PREFLIGHT_PATH) {
        const preflightToken = env.GITHUB_APP_AUTH_PREFLIGHT_TOKEN;
        if (
          !preflightToken ||
          request.headers.get("authorization") !== `Bearer ${preflightToken}`
        ) {
          return jsonResponse({ error: "not_found" }, 404);
        }

        try {
          await preflightDispatchIdentity(config, env, fetchImpl);
        } catch (error) {
          const detail = describeGitHubAppAuthenticationError(error);
          console.error(`GitHub App authentication preflight failed: ${detail}`);
          return jsonResponse({ error: "github_app_authentication_failed", detail }, 502);
        }
        return new Response(null, { status: 204 });
      }

      const mirrorId = parseMirrorId(url.pathname, config.worker.path_prefix);
      const mirror = mirrorId ? mirrorIndex.get(mirrorId) : undefined;
      if (!mirror || !mirror.enabled) {
        return jsonResponse({ error: "not_found" }, 404);
      }

      if (request.headers.get("x-event-key") !== "repo:push") {
        return jsonResponse({ error: "unsupported_event" }, 400);
      }

      const signature = request.headers.get("x-hub-signature");
      const secretBinding = deriveWebhookSecretBinding(mirror.id);
      const webhookSecret = env[secretBinding];
      if (!signature) {
        return jsonResponse({ error: "missing_signature" }, 401);
      }
      if (!webhookSecret) {
        console.error(`Missing Worker secret binding for mirror ${mirror.id}.`);
        return jsonResponse({ error: "service_unavailable" }, 503);
      }

      const rawBody = await request.arrayBuffer();
      if (!(await verifyBitbucketSignature(signature, webhookSecret, rawBody))) {
        return jsonResponse({ error: "invalid_signature" }, 401);
      }

      let payload;
      try {
        payload = JSON.parse(new TextDecoder().decode(rawBody));
      } catch {
        return jsonResponse({ error: "invalid_json" }, 400);
      }
      if (!isObject(payload) || !isObject(payload.repository)) {
        return jsonResponse({ error: "invalid_payload" }, 400);
      }
      if (payload.repository.full_name !== mirror.bitbucket_repository) {
        return jsonResponse({ error: "repository_mismatch" }, 400);
      }

      if (
        !config.dispatch.github_app_id ||
        !config.dispatch.github_app_installation_id ||
        !env.GITHUB_APP_PRIVATE_KEY
      ) {
        console.error("Missing GitHub App dispatch identity configuration.");
        return jsonResponse({ error: "service_unavailable" }, 503);
      }

      let dispatchToken;
      try {
        dispatchToken = await getDispatchToken(config, env, fetchImpl);
      } catch (error) {
        const detail = describeGitHubAppAuthenticationError(error);
        console.error(`GitHub App installation authentication failed for ${mirror.id}: ${detail}`);
        return jsonResponse({ error: "dispatch_failed" }, 502);
      }

      const dispatchUrl = `https://api.github.com/repos/${encodeRepositoryPath(config.dispatch.github_repository)}` +
        `/actions/workflows/${encodeURIComponent(config.dispatch.workflow_file)}/dispatches`;
      const dispatchResponse = await fetchImpl(dispatchUrl, {
        method: "POST",
        headers: {
          accept: "application/vnd.github+json",
          authorization: `Bearer ${dispatchToken}`,
          "content-type": "application/json",
          "user-agent": "bitbucket-mirror-dispatch-worker",
          "x-github-api-version": "2022-11-28"
        },
        body: JSON.stringify({
          ref: config.dispatch.ref,
          inputs: { mirror_id: mirror.id }
        })
      });

      if (dispatchResponse.status !== 204) {
        console.error(`GitHub workflow dispatch failed for ${mirror.id}: HTTP ${dispatchResponse.status}.`);
        return jsonResponse({ error: "dispatch_failed" }, 502);
      }

      return jsonResponse({ accepted: true, mirror_id: mirror.id }, 202);
    }
  };
}
