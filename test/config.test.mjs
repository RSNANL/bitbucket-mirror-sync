import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  deriveEnvironmentName,
  deriveWebhookSecretBinding,
  getMirror,
  validateConfig
} from "../scripts/config-lib.mjs";

function baseConfig() {
  return {
    worker: { base_url: "https://worker.example", path_prefix: "/webhooks" },
    dispatch: {
      github_repository: "RSNANL/bitbucket-mirror-sync",
      workflow_file: "mirror.yml",
      ref: "main",
      github_app_id: 1234567,
      github_app_installation_id: 12345678
    },
    mirrors: []
  };
}

function mirror(id = "generic-vacuum-statemachine-blueprint") {
  return {
    id,
    enabled: true,
    bitbucket_repository: `rsna_nl/${id}`,
    github_repository: `RSNANL/${id}-mirror`,
    scheduled_recovery: false
  };
}

test("accepts an empty inactive configuration before Worker bootstrap", () => {
  const config = baseConfig();
  config.worker.base_url = null;
  config.dispatch.github_app_id = null;
  config.dispatch.github_app_installation_id = null;
  assert.deepEqual(validateConfig(config), []);
});

test("derives environment and secret binding from the mirror id", () => {
  assert.equal(
    deriveEnvironmentName("generic-vacuum-statemachine-blueprint"),
    "mirror-generic-vacuum-statemachine-blueprint"
  );
  assert.equal(
    deriveWebhookSecretBinding("generic-vacuum-statemachine-blueprint"),
    "WEBHOOK_GENERIC_VACUUM_STATEMACHINE_BLUEPRINT"
  );
});

test("rejects duplicate ids, sources and targets", () => {
  const config = baseConfig();
  const first = mirror();
  config.mirrors = [first, { ...first }];
  const errors = validateConfig(config).join("\n");
  assert.match(errors, /Duplicate mirror id/);
  assert.match(errors, /Duplicate Bitbucket source/);
  assert.match(errors, /Duplicate GitHub target/);
});

test("rejects repository duplicates regardless of letter case", () => {
  const config = baseConfig();
  const first = mirror("first");
  const second = {
    ...mirror("second"),
    bitbucket_repository: first.bitbucket_repository.toUpperCase(),
    github_repository: first.github_repository.toLowerCase()
  };
  config.mirrors = [first, second];
  const errors = validateConfig(config).join("\n");
  assert.match(errors, /Duplicate Bitbucket source/);
  assert.match(errors, /Duplicate GitHub target/);
});

test("requires the Worker base URL to be a clean HTTPS origin", () => {
  const config = baseConfig();
  config.worker.base_url = "https://worker.example";
  assert.deepEqual(validateConfig(config), []);
  for (const invalid of [
    "http://worker.example",
    "https://worker.example/base",
    "https://user@worker.example",
    "https://worker.example?query=true",
    "https://worker.example#fragment"
  ]) {
    config.worker.base_url = invalid;
    assert.match(validateConfig(config).join("\n"), /clean HTTPS origin/);
  }
});

test("rejects secret values in configuration", () => {
  const config = baseConfig();
  config.mirrors.push({ ...mirror(), webhook_secret: "must-not-be-here" });
  assert.match(validateConfig(config).join("\n"), /secret values must not be stored/);
});

test("requires complete non-secret GitHub App dispatch identifiers", () => {
  const config = baseConfig();
  config.dispatch.github_app_id = null;
  config.dispatch.github_app_installation_id = null;
  config.dispatch.github_app_id = 1234567;
  assert.match(validateConfig(config).join("\n"), /App and installation IDs/);
  config.dispatch.github_app_installation_id = 12345678;
  assert.deepEqual(validateConfig(config), []);
});

test("requires the GitHub App ID to be a positive integer", () => {
  const config = baseConfig();
  config.dispatch.github_app_id = "Iv23liExampleClientId";
  assert.match(validateConfig(config).join("\n"), /github_app_id must be null or a positive integer/);
});

test("returns enriched derived mirror data", () => {
  const config = baseConfig();
  config.mirrors.push(mirror());
  const resolved = getMirror(config, "generic-vacuum-statemachine-blueprint", { requireEnabled: true });
  assert.equal(resolved.github_environment, "mirror-generic-vacuum-statemachine-blueprint");
  assert.equal(resolved.webhook_secret_binding, "WEBHOOK_GENERIC_VACUUM_STATEMACHINE_BLUEPRINT");
  assert.equal(resolved.webhook_path, "/webhooks/generic-vacuum-statemachine-blueprint");
});

test("add and remove CLI scripts preserve a valid configuration", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "mirror-config-test-"));
  const configPath = path.join(directory, "mirrors.json");
  fs.writeFileSync(configPath, JSON.stringify(baseConfig()));
  const { spawnSync } = await import("node:child_process");
  const add = spawnSync(process.execPath, [
    "scripts/add-mirror-config.mjs",
    "--config", configPath,
    "--id", "generic-vacuum-statemachine-blueprint",
    "--source", "rsna_nl/generic-vacuum-statemachine-blueprint",
    "--target", "RSNANL/generic-vacuum-statemachine-blueprint-mirror"
  ], { cwd: path.resolve("."), encoding: "utf8" });
  assert.equal(add.status, 0, add.stderr);
  assert.equal(JSON.parse(fs.readFileSync(configPath, "utf8")).mirrors.length, 1);
  const remove = spawnSync(process.execPath, [
    "scripts/remove-mirror-config.mjs",
    "--config", configPath,
    "--id", "generic-vacuum-statemachine-blueprint"
  ], { cwd: path.resolve("."), encoding: "utf8" });
  assert.equal(remove.status, 0, remove.stderr);
  assert.equal(JSON.parse(fs.readFileSync(configPath, "utf8")).mirrors.length, 0);
  fs.rmSync(directory, { recursive: true, force: true });
});

test("dispatch identity CLI stores only the public GitHub App identifiers", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "mirror-dispatch-test-"));
  const configPath = path.join(directory, "mirrors.json");
  fs.writeFileSync(configPath, JSON.stringify(baseConfig()));
  const { spawnSync } = await import("node:child_process");
  const update = spawnSync(process.execPath, [
    "scripts/set-github-dispatch-identity.mjs",
    "--config", configPath,
    "--app-id", "1234567",
    "--installation-id", "12345678"
  ], { cwd: path.resolve("."), encoding: "utf8" });
  assert.equal(update.status, 0, update.stderr);
  const updated = JSON.parse(fs.readFileSync(configPath, "utf8"));
  assert.equal(updated.dispatch.github_app_id, 1234567);
  assert.equal(updated.dispatch.github_app_installation_id, 12345678);
  assert.deepEqual(validateConfig(updated), []);
  fs.rmSync(directory, { recursive: true, force: true });
});

test("recovery matrix selects only enabled mirrors with scheduled recovery", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "mirror-recovery-test-"));
  const configPath = path.join(directory, "mirrors.json");
  const config = baseConfig();
  config.mirrors = [
    { ...mirror("scheduled"), scheduled_recovery: true },
    { ...mirror("manual-only"), scheduled_recovery: false },
    { ...mirror("disabled"), enabled: false, scheduled_recovery: true }
  ];
  fs.writeFileSync(configPath, JSON.stringify(config));
  const { spawnSync } = await import("node:child_process");
  const environment = { ...process.env };
  delete environment.GITHUB_OUTPUT;
  const resolved = spawnSync(process.execPath, [
    "scripts/resolve-recovery-matrix.mjs",
    configPath
  ], { cwd: path.resolve("."), encoding: "utf8", env: environment });
  assert.equal(resolved.status, 0, resolved.stderr);
  assert.deepEqual(JSON.parse(resolved.stdout), [{
    mirror_id: "scheduled",
    source_repository: "rsna_nl/scheduled",
    target_repository: "RSNANL/scheduled-mirror",
    environment_name: "mirror-scheduled"
  }]);
  fs.rmSync(directory, { recursive: true, force: true });
});

test("workflow triggers retain all-PR validation and daily recovery", () => {
  const validationWorkflow = fs.readFileSync(".github/workflows/validate.yml", "utf8");
  assert.match(validationWorkflow, /pull_request:/);
  assert.doesNotMatch(validationWorkflow, /pull_request:\n\s+branches:/);
  assert.match(validationWorkflow, /workflow_dispatch:/);

  const recoveryWorkflow = fs.readFileSync(".github/workflows/mirror-recovery.yml", "utf8");
  assert.match(recoveryWorkflow, /workflow_dispatch:/);
  assert.match(recoveryWorkflow, /cron: "17 3 \* \* \*"/);
});
