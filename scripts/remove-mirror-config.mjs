#!/usr/bin/env node
import fs from "node:fs";
import { readConfig, validateConfig } from "./config-lib.mjs";

const args = process.argv.slice(2);
const option = (name, fallback = null) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};
const configPath = option("--config", "config/mirrors.json");
const mirrorId = option("--id");
if (!mirrorId) {
  console.error("Usage: remove-mirror-config.mjs --id <mirror-id> [--config <path>].");
  process.exit(2);
}

try {
  const { config, absolutePath } = readConfig(configPath);
  const originalLength = config.mirrors.length;
  config.mirrors = config.mirrors.filter((mirror) => mirror.id !== mirrorId);
  if (config.mirrors.length === originalLength) throw new Error(`Mirror not found: ${mirrorId}.`);
  const errors = validateConfig(config);
  if (errors.length > 0) throw new Error(errors.join("\n"));
  fs.writeFileSync(absolutePath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o644 });
  console.log(`Removed mirror configuration: ${mirrorId}.`);
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
