#!/usr/bin/env node
import fs from "node:fs";
import { readConfig, validateConfig } from "./config-lib.mjs";

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  args.set(process.argv[index], process.argv[index + 1]);
}

const configPath = args.get("--config") ?? "config/mirrors.json";
const clientId = args.get("--client-id");
const installationId = Number(args.get("--installation-id"));
if (!clientId || !/^[A-Za-z0-9_-]+$/.test(clientId)) {
  throw new Error("--client-id must be a GitHub App client ID.");
}
if (!Number.isSafeInteger(installationId) || installationId < 1) {
  throw new Error("--installation-id must be a positive integer.");
}

const { config, absolutePath } = readConfig(configPath);
config.dispatch.github_app_client_id = clientId;
config.dispatch.github_app_installation_id = installationId;
const errors = validateConfig(config);
if (errors.length > 0) throw new Error(errors.join("\n"));
fs.writeFileSync(absolutePath, `${JSON.stringify(config, null, 2)}\n`, "utf8");
console.log("Updated GitHub App dispatch identity.");
