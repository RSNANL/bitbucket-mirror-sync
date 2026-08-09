#!/usr/bin/env node
import fs from "node:fs";
import { deriveEnvironmentName, readConfig, validateConfig } from "./config-lib.mjs";

const configPath = process.argv[2] ?? "config/mirrors.json";
try {
  const { config } = readConfig(configPath);
  const errors = validateConfig(config);
  if (errors.length > 0) throw new Error(errors.join("\n"));
  const matrix = config.mirrors
    .filter((mirror) => mirror.enabled && mirror.scheduled_recovery)
    .map((mirror) => ({
      mirror_id: mirror.id,
      source_repository: mirror.bitbucket_repository,
      target_repository: mirror.github_repository,
      environment_name: deriveEnvironmentName(mirror.id)
    }));
  const json = JSON.stringify(matrix);
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `matrix=${json}\ncount=${matrix.length}\n`);
  } else {
    console.log(json);
  }
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
