import fs from "node:fs";
import path from "node:path";

const REPOSITORY_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const MIRROR_ID_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const WORKFLOW_PATTERN = /^[A-Za-z0-9_.-]+\.ya?ml$/;
const PATH_PREFIX_PATTERN = /^\/[a-z0-9/_-]*[a-z0-9_-]$/;
const FORBIDDEN_SECRET_KEYS = new Set([
  "secret",
  "webhook_secret",
  "private_key",
  "ssh_private_key",
  "token",
  "password",
  "api_token"
]);

export function deriveEnvironmentName(mirrorId) {
  return `mirror-${mirrorId}`;
}

export function deriveWebhookSecretBinding(mirrorId) {
  return `WEBHOOK_${mirrorId.replaceAll("-", "_").toUpperCase()}`;
}

export function deriveWebhookPath(config, mirrorId) {
  return `${config.worker.path_prefix}/${mirrorId}`;
}

export function readConfig(filePath) {
  const absolutePath = path.resolve(filePath);
  const raw = fs.readFileSync(absolutePath, "utf8");
  let config;
  try {
    config = JSON.parse(raw);
  } catch (error) {
    throw new Error(`Configuration is not valid JSON: ${error.message}`);
  }
  return { config, absolutePath };
}

function assertObject(value, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object.`);
  }
}

function assertExactKeys(value, allowed, label) {
  const keys = Object.keys(value);
  const unknown = keys.filter((key) => !allowed.includes(key));
  if (unknown.length > 0) {
    throw new Error(`${label} contains unsupported field(s): ${unknown.join(", ")}.`);
  }
}

function scanForbiddenSecretFields(value, location = "config") {
  if (Array.isArray(value)) {
    value.forEach((item, index) => scanForbiddenSecretFields(item, `${location}[${index}]`));
    return;
  }
  if (value === null || typeof value !== "object") {
    return;
  }
  for (const [key, child] of Object.entries(value)) {
    if (FORBIDDEN_SECRET_KEYS.has(key.toLowerCase())) {
      throw new Error(`${location}.${key} is forbidden; secret values must not be stored in configuration.`);
    }
    scanForbiddenSecretFields(child, `${location}.${key}`);
  }
}

export function validateConfig(config) {
  const errors = [];
  const fail = (message) => errors.push(message);

  try {
    assertObject(config, "Configuration");
    assertExactKeys(config, ["worker", "dispatch", "mirrors"], "Configuration");
    scanForbiddenSecretFields(config);
  } catch (error) {
    return [error.message];
  }

  try {
    assertObject(config.worker, "worker");
    assertExactKeys(config.worker, ["base_url", "path_prefix"], "worker");
    if (config.worker.base_url !== null) {
      if (typeof config.worker.base_url !== "string" || !config.worker.base_url.startsWith("https://")) {
        fail("worker.base_url must be null or an HTTPS URL.");
      } else {
        try {
          const url = new URL(config.worker.base_url);
          if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
            fail("worker.base_url must be a clean HTTPS base URL without credentials, query or fragment.");
          }
        } catch {
          fail("worker.base_url is not a valid URL.");
        }
      }
    }
    if (typeof config.worker.path_prefix !== "string" || !PATH_PREFIX_PATTERN.test(config.worker.path_prefix)) {
      fail("worker.path_prefix must be a lowercase absolute path such as /webhooks.");
    }
  } catch (error) {
    fail(error.message);
  }

  try {
    assertObject(config.dispatch, "dispatch");
    assertExactKeys(
      config.dispatch,
      [
        "github_repository",
        "workflow_file",
        "ref",
        "github_app_client_id",
        "github_app_installation_id"
      ],
      "dispatch"
    );
    if (typeof config.dispatch.github_repository !== "string" || !REPOSITORY_PATTERN.test(config.dispatch.github_repository)) {
      fail("dispatch.github_repository must use owner/repository notation.");
    }
    if (typeof config.dispatch.workflow_file !== "string" || !WORKFLOW_PATTERN.test(config.dispatch.workflow_file)) {
      fail("dispatch.workflow_file must be a workflow YAML filename.");
    }
    if (typeof config.dispatch.ref !== "string" || config.dispatch.ref.length === 0) {
      fail("dispatch.ref must be a non-empty Git ref.");
    }
    if (
      config.dispatch.github_app_client_id !== null &&
      (
        typeof config.dispatch.github_app_client_id !== "string" ||
        !/^[A-Za-z0-9_-]+$/.test(config.dispatch.github_app_client_id)
      )
    ) {
      fail("dispatch.github_app_client_id must be null or a GitHub App client ID.");
    }
    if (
      config.dispatch.github_app_installation_id !== null &&
      (
        !Number.isSafeInteger(config.dispatch.github_app_installation_id) ||
        config.dispatch.github_app_installation_id < 1
      )
    ) {
      fail("dispatch.github_app_installation_id must be null or a positive integer.");
    }
    if (
      (config.dispatch.github_app_client_id === null) !==
      (config.dispatch.github_app_installation_id === null)
    ) {
      fail("GitHub App client and installation IDs must either both be configured or both be null.");
    }
  } catch (error) {
    fail(error.message);
  }

  if (!Array.isArray(config.mirrors)) {
    fail("mirrors must be an array.");
    return errors;
  }
  if (
    config.mirrors.length > 0 &&
    (
      config.dispatch.github_app_client_id === null ||
      config.dispatch.github_app_installation_id === null
    )
  ) {
    fail("GitHub App dispatch identifiers must be configured before enabling a mirror.");
  }

  const ids = new Set();
  const sources = new Set();
  const targets = new Set();
  const environments = new Set();
  const bindings = new Set();

  config.mirrors.forEach((mirror, index) => {
    const label = `mirrors[${index}]`;
    try {
      assertObject(mirror, label);
      assertExactKeys(
        mirror,
        ["id", "enabled", "bitbucket_repository", "github_repository", "scheduled_recovery"],
        label
      );
    } catch (error) {
      fail(error.message);
      return;
    }

    if (typeof mirror.id !== "string" || mirror.id.length > 48 || !MIRROR_ID_PATTERN.test(mirror.id)) {
      fail(`${label}.id must be a lowercase kebab-case identifier of at most 48 characters.`);
    }
    if (typeof mirror.enabled !== "boolean") {
      fail(`${label}.enabled must be boolean.`);
    }
    if (typeof mirror.scheduled_recovery !== "boolean") {
      fail(`${label}.scheduled_recovery must be boolean.`);
    }
    if (typeof mirror.bitbucket_repository !== "string" || !REPOSITORY_PATTERN.test(mirror.bitbucket_repository)) {
      fail(`${label}.bitbucket_repository must use workspace/repository notation.`);
    }
    if (typeof mirror.github_repository !== "string" || !REPOSITORY_PATTERN.test(mirror.github_repository)) {
      fail(`${label}.github_repository must use owner/repository notation.`);
    }

    if (typeof mirror.id === "string") {
      const environment = deriveEnvironmentName(mirror.id);
      const binding = deriveWebhookSecretBinding(mirror.id);
      for (const [set, value, name] of [
        [ids, mirror.id, "mirror id"],
        [environments, environment, "derived environment"],
        [bindings, binding, "derived webhook binding"]
      ]) {
        if (set.has(value)) fail(`Duplicate ${name}: ${value}.`);
        set.add(value);
      }
    }
    if (typeof mirror.bitbucket_repository === "string") {
      if (sources.has(mirror.bitbucket_repository)) fail(`Duplicate Bitbucket source: ${mirror.bitbucket_repository}.`);
      sources.add(mirror.bitbucket_repository);
    }
    if (typeof mirror.github_repository === "string") {
      if (targets.has(mirror.github_repository)) fail(`Duplicate GitHub target: ${mirror.github_repository}.`);
      targets.add(mirror.github_repository);
    }
  });

  return errors;
}

export function getMirror(config, mirrorId, { requireEnabled = false } = {}) {
  const mirror = config.mirrors.find((candidate) => candidate.id === mirrorId);
  if (!mirror) {
    throw new Error(`Unknown mirror id: ${mirrorId}.`);
  }
  if (requireEnabled && !mirror.enabled) {
    throw new Error(`Mirror is disabled: ${mirrorId}.`);
  }
  return {
    ...mirror,
    github_environment: deriveEnvironmentName(mirror.id),
    webhook_secret_binding: deriveWebhookSecretBinding(mirror.id),
    webhook_path: deriveWebhookPath(config, mirror.id)
  };
}
