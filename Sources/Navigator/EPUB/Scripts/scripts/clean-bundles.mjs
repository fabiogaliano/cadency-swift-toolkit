#!/usr/bin/env node
// Removes only the generated readium-*.js / readium-*.js.map bundles from the
// output dir, ahead of a fresh `vp run bundle`. Deliberately does not touch
// readium-continuous-wrapper-shim.js: that file has no bundler entry and is
// never regenerated, so a naive `rm readium-*.js` would delete a committed
// hand-authored asset the build can't put back.
import { existsSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { BUNDLE_NAMES } from "./bundle-manifest.mjs";
import { resolveOutDir } from "./verify-bundles.mjs";

export function cleanBundles(outDir) {
  const removed = [];
  for (const name of BUNDLE_NAMES) {
    for (const fileName of [name, `${name}.map`]) {
      const filePath = path.join(outDir, fileName);
      if (existsSync(filePath)) {
        rmSync(filePath);
        removed.push(filePath);
      }
    }
  }
  return removed;
}

const isMain =
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
  const outDir = resolveOutDir();
  const removed = cleanBundles(outDir);
  console.log(
    `Removed ${removed.length} generated bundle file(s) from ${outDir}`
  );
}
