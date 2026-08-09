#!/usr/bin/env node
import { getMirror, readConfig, validateConfig } from "./config-lib.mjs";

const args = process.argv.slice(2);
const option = (name, fallback = null) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};
const configPath = option("--config", "config/mirrors.json");
const mirrorId = option("--id");
const outputFile = process.env.GITHUB_OUTPUT ?? option("--github-output");

if (!mirrorId) {
  console.error("Usage: resolve-mirror.mjs --id <mirror-id> [--config <path>].");
  process.exit(2);
}

try {
  const { config } = readConfig(configPath);
  const errors = validateConfig(config);
  if (errors.length > 0) throw new Error(errors.join("\n"));
  const mirror = getMirror(config, mirrorId, { requireEnabled: true });
  const outputs = {
    mirror_id: mirror.id,
    source_repository: mirror.bitbucket_repository,
    target_repository: mirror.github_repository,
    environment_name: mirror.github_environment,
    webhook_secret_binding: mirror.webhook_secret_binding
  };
  if (outputFile) {
    const fs = await import("node:fs");
    fs.appendFileSync(outputFile, Object.entries(outputs).map(([key, value]) => `${key}=${value}\n`).join(""));
  } else {
    console.log(JSON.stringify(outputs, null, 2));
  }
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
