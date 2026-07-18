#!/usr/bin/env node
// Fails the build unless the bundle output directory contains exactly the
// five fixed-name IIFEs and their five source maps, plus known static assets
// and repository metadata. Every generated file must be non-empty, and each
// IIFE must carry its documented global-API marker.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  BUNDLE_NAMES,
  GENERATED_BUNDLE_NAMES,
  GLOBAL_MARKERS,
  OUTPUT_METADATA_NAMES,
  REQUIRED_OUTPUT_NAMES,
  STATIC_ASSET_NAMES,
  resolveBundleOutDir,
} from "./bundle-manifest.mjs";

export class BundleVerificationError extends Error {}

// Resolution order: explicit argv[0] > BUNDLE_OUT_DIR env var > the
// committed output dir. Both overrides exist so tests and the Step 2
// rehearsal build can point this at a disposable directory instead of the
// real committed assets.
export function resolveOutDir(argv = process.argv.slice(2), env = process.env) {
  return resolveBundleOutDir(argv[0] || env.BUNDLE_OUT_DIR);
}

// Throws BundleVerificationError on any violation; otherwise returns the
// list of verified bundle paths.
export function verifyBundles(outDir) {
  if (!existsSync(outDir) || !statSync(outDir).isDirectory()) {
    throw new BundleVerificationError(
      `Bundle output directory not found: ${outDir}`
    );
  }

  const entries = readdirSync(outDir);
  const allowed = new Set([
    ...GENERATED_BUNDLE_NAMES,
    ...STATIC_ASSET_NAMES,
    ...OUTPUT_METADATA_NAMES,
  ]);

  const errors = [];

  const missing = REQUIRED_OUTPUT_NAMES.filter(
    (name) => !entries.includes(name)
  );
  if (missing.length > 0) {
    errors.push(`missing generated file(s): ${missing.join(", ")}`);
  }

  const unexpected = entries.filter((name) => !allowed.has(name));
  if (unexpected.length > 0) {
    errors.push(
      `unexpected output entry or chunk(s): ${unexpected.join(", ")}`
    );
  }

  for (const name of REQUIRED_OUTPUT_NAMES) {
    if (!entries.includes(name)) continue; // already reported above

    const filePath = path.join(outDir, name);
    const stats = statSync(filePath);
    if (!stats.isFile()) {
      errors.push(`${name} is not a file`);
      continue;
    }
    if (stats.size === 0) {
      errors.push(`${name} is empty (0 bytes)`);
      continue;
    }

    const marker = GLOBAL_MARKERS[name];
    if (marker && !marker.test(readFileSync(filePath, "utf8"))) {
      errors.push(
        `${name} does not initialize its expected global API (expected to match ${marker})`
      );
    }
  }

  if (errors.length > 0) {
    throw new BundleVerificationError(
      `Bundle verification failed for ${outDir}:\n  - ${errors.join("\n  - ")}`
    );
  }

  return BUNDLE_NAMES.map((name) => path.join(outDir, name));
}

const isMain =
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
  const outDir = resolveOutDir();
  try {
    const verified = verifyBundles(outDir);
    console.log(
      `Bundle verification passed: ${verified.length} bundle(s) OK in ${outDir}`
    );
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}
