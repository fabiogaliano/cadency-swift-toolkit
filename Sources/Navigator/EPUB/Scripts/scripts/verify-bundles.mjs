#!/usr/bin/env node
// Fails the build unless the bundle output directory contains exactly the
// five committed readium-*.js artifacts (plus the known static shim), each
// non-empty and each carrying its documented global-API marker. Guards
// against silently shipping a hashed/code-split chunk name that Swift/HTML
// wouldn't know how to load.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  BUNDLE_NAMES,
  DEFAULT_OUT_DIR,
  GLOBAL_MARKERS,
  STATIC_ASSET_NAMES,
} from "./bundle-manifest.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export class BundleVerificationError extends Error {}

// Resolution order: explicit argv[0] > BUNDLE_OUT_DIR env var > the
// committed output dir. Both overrides exist so tests and the Step 2
// rehearsal build can point this at a disposable directory instead of the
// real committed assets.
export function resolveOutDir(argv = process.argv.slice(2), env = process.env) {
  const requested = argv[0] || env.BUNDLE_OUT_DIR || DEFAULT_OUT_DIR;
  return path.resolve(__dirname, requested);
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
  const jsFiles = entries.filter((name) => name.endsWith(".js"));
  const allowed = new Set([...BUNDLE_NAMES, ...STATIC_ASSET_NAMES]);

  const errors = [];

  const missing = BUNDLE_NAMES.filter((name) => !jsFiles.includes(name));
  if (missing.length > 0) {
    errors.push(`missing bundle(s): ${missing.join(", ")}`);
  }

  const unexpected = jsFiles.filter((name) => !allowed.has(name));
  if (unexpected.length > 0) {
    errors.push(
      `unexpected .js file(s): ${unexpected.join(", ")} ` +
        `(hashed names and extra chunks are not allowed; only ${BUNDLE_NAMES.join(
          ", "
        )} and the static ${STATIC_ASSET_NAMES.join(", ")} may live in ${outDir})`
    );
  }

  for (const name of BUNDLE_NAMES) {
    if (!jsFiles.includes(name)) continue; // already reported above

    const filePath = path.join(outDir, name);
    if (statSync(filePath).size === 0) {
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
