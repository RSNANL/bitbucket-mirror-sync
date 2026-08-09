#!/usr/bin/env node
import fs from "node:fs";
import { readConfig, validateConfig } from "./config-lib.mjs";

const args = process.argv.slice(2);
const option = (name, fallback = null) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};
const configPath = option("--config", "config/mirrors.json");
const baseUrl = option("--url");
if (!baseUrl) {
  console.error("Usage: set-worker-base-url.mjs --url <https-url> [--config <path>].");
  process.exit(2);
}
try {
  const { config, absolutePath } = readConfig(configPath);
  config.worker.base_url = baseUrl.replace(/\/+$/, "");
  const errors = validateConfig(config);
  if (errors.length > 0) throw new Error(errors.join("\n"));
  fs.writeFileSync(absolutePath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o644 });
  console.log(`Updated Worker base URL: ${config.worker.base_url}.`);
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
