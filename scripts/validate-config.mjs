#!/usr/bin/env node
import { readConfig, validateConfig } from "./config-lib.mjs";

const configPath = process.argv[2] ?? "config/mirrors.json";
try {
  const { config, absolutePath } = readConfig(configPath);
  const errors = validateConfig(config);
  if (errors.length > 0) {
    console.error(`Invalid mirror configuration: ${absolutePath}`);
    errors.forEach((error) => console.error(`- ${error}`));
    process.exit(1);
  }
  console.log(`Mirror configuration is valid: ${absolutePath}`);
  console.log(`Configured mirrors: ${config.mirrors.length}`);
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
