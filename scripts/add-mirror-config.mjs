#!/usr/bin/env node
import fs from "node:fs";
import { readConfig, validateConfig } from "./config-lib.mjs";

const args = process.argv.slice(2);
const option = (name, fallback = null) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};
const required = (name) => {
  const value = option(name);
  if (!value) throw new Error(`Missing required option ${name}.`);
  return value;
};

try {
  const configPath = option("--config", "config/mirrors.json");
  const id = required("--id");
  const source = required("--source");
  const target = required("--target");
  const enabled = option("--enabled", "true") === "true";
  const scheduledRecovery = option("--scheduled-recovery", "false") === "true";
  const { config, absolutePath } = readConfig(configPath);
  if (config.mirrors.some((mirror) => mirror.id === id)) {
    throw new Error(`Mirror already exists in configuration: ${id}.`);
  }
  config.mirrors.push({
    id,
    enabled,
    bitbucket_repository: source,
    github_repository: target,
    scheduled_recovery: scheduledRecovery
  });
  config.mirrors.sort((left, right) => left.id.localeCompare(right.id));
  const errors = validateConfig(config);
  if (errors.length > 0) throw new Error(errors.join("\n"));
  fs.writeFileSync(absolutePath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o644 });
  console.log(`Added mirror configuration: ${id}.`);
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
