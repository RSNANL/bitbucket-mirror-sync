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
    worker: { base_url: null, path_prefix: "/webhooks" },
    dispatch: {
      github_repository: "RSNANL/bitbucket-mirror-sync",
      workflow_file: "mirror.yml",
      ref: "main"
    },
    mirrors: []
  };
}

function mirror(id = "roomba-automation") {
  return {
    id,
    enabled: true,
    bitbucket_repository: `rsna_nl/${id}`,
    github_repository: `RSNANL/${id}-mirror`,
    scheduled_recovery: false
  };
}

test("accepts an empty inactive configuration", () => {
  assert.deepEqual(validateConfig(baseConfig()), []);
});

test("derives environment and secret binding from the mirror id", () => {
  assert.equal(deriveEnvironmentName("roomba-automation"), "mirror-roomba-automation");
  assert.equal(deriveWebhookSecretBinding("roomba-automation"), "WEBHOOK_ROOMBA_AUTOMATION");
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

test("rejects secret values in configuration", () => {
  const config = baseConfig();
  config.mirrors.push({ ...mirror(), webhook_secret: "must-not-be-here" });
  assert.match(validateConfig(config).join("\n"), /secret values must not be stored/);
});

test("returns enriched derived mirror data", () => {
  const config = baseConfig();
  config.mirrors.push(mirror());
  const resolved = getMirror(config, "roomba-automation", { requireEnabled: true });
  assert.equal(resolved.github_environment, "mirror-roomba-automation");
  assert.equal(resolved.webhook_secret_binding, "WEBHOOK_ROOMBA_AUTOMATION");
  assert.equal(resolved.webhook_path, "/webhooks/roomba-automation");
});

test("add and remove CLI scripts preserve a valid configuration", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "mirror-config-test-"));
  const configPath = path.join(directory, "mirrors.json");
  fs.writeFileSync(configPath, JSON.stringify(baseConfig()));
  const { spawnSync } = await import("node:child_process");
  const add = spawnSync(process.execPath, [
    "scripts/add-mirror-config.mjs",
    "--config", configPath,
    "--id", "roomba-automation",
    "--source", "rsna_nl/roomba-automation",
    "--target", "RSNANL/roomba-automation-mirror"
  ], { cwd: path.resolve("."), encoding: "utf8" });
  assert.equal(add.status, 0, add.stderr);
  assert.equal(JSON.parse(fs.readFileSync(configPath, "utf8")).mirrors.length, 1);
  const remove = spawnSync(process.execPath, [
    "scripts/remove-mirror-config.mjs",
    "--config", configPath,
    "--id", "roomba-automation"
  ], { cwd: path.resolve("."), encoding: "utf8" });
  assert.equal(remove.status, 0, remove.stderr);
  assert.equal(JSON.parse(fs.readFileSync(configPath, "utf8")).mirrors.length, 0);
  fs.rmSync(directory, { recursive: true, force: true });
});
