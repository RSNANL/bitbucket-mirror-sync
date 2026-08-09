#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(process.argv[2] ?? ".");
const ignored = new Set([".git", "node_modules", ".wrangler", "dist", "coverage"]);
const patterns = [
  { name: "private SSH key", regex: /-----BEGIN (?:OPENSSH|RSA|EC|DSA) PRIVATE KEY-----/ },
  { name: "GitHub classic token", regex: /ghp_[A-Za-z0-9]{30,}/ },
  { name: "GitHub fine-grained token", regex: /github_pat_[A-Za-z0-9_]{40,}/ },
  { name: "GitHub App user access token", regex: /ghu_[A-Za-z0-9]{30,}/ },
  { name: "GitHub App refresh token", regex: /ghr_[A-Za-z0-9]{30,}/ },
  { name: "Cloudflare API token assignment", regex: /CLOUDFLARE_API_TOKEN\s*[:=]\s*["']?[A-Za-z0-9_-]{20,}/i },
  { name: "Bitbucket API token assignment", regex: /BITBUCKET_API_TOKEN\s*[:=]\s*["']?[A-Za-z0-9_-]{20,}/i },
  { name: "OAuth client secret assignment", regex: /(?:client[_-]?secret|oauth[_-]?secret)\s*[:=]\s*["'][^"'\r\n]{12,}["']/i }
];
const findings = [];

function walk(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (ignored.has(entry.name)) continue;
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      walk(fullPath);
      continue;
    }
    const stat = fs.statSync(fullPath);
    if (stat.size > 1_000_000) continue;
    const content = fs.readFileSync(fullPath, "utf8");
    for (const pattern of patterns) {
      if (pattern.regex.test(content)) findings.push(`${path.relative(root, fullPath)}: ${pattern.name}`);
    }
  }
}

walk(root);
if (findings.length > 0) {
  console.error("Potential secret material detected:");
  findings.forEach((finding) => console.error(`- ${finding}`));
  process.exit(1);
}
console.log("No known secret material patterns detected.");
