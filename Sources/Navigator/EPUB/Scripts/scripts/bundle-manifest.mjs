// Single source of truth for the engine's five-entry bundle contract.
// vite.config.ts, verify-bundles.mjs, and clean-bundles.mjs all import this
// so the mode list, output names, and static exceptions can never drift
// apart from each other.
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Closed map of build mode -> entry module. Any mode outside this map (or a
// missing/default mode) must fail loudly rather than silently building one
// entry — see vite.config.ts.
export const BUNDLE_MODES = {
  reflowable: "src/index-reflowable.js",
  fixed: "src/index-fixed.js",
  "fixed-wrapper-one": "src/index-fixed-wrapper-one.js",
  "fixed-wrapper-two": "src/index-fixed-wrapper-two.js",
  "continuous-wrapper": "src/index-continuous-wrapper.js",
};

export const BUNDLE_NAMES = Object.keys(BUNDLE_MODES).map(
  (mode) => `readium-${mode}.js`
);

export const BUNDLE_MAP_NAMES = BUNDLE_NAMES.map((name) => `${name}.map`);

export const GENERATED_BUNDLE_NAMES = [...BUNDLE_NAMES, ...BUNDLE_MAP_NAMES];

// Hand-authored static assets that permanently live in the bundle output
// directory alongside the five generated IIFEs. `readium-continuous-wrapper-shim.js`
// is loaded directly by WrapperPreparationEngine.swift by filename; it has no
// src/ entry and is never produced by a bundler, so it is excluded from both
// the verifier's exact-file check and the cleaner's deletion pass.
export const STATIC_ASSET_NAMES = ["readium-continuous-wrapper-shim.js"];

export const REQUIRED_OUTPUT_NAMES = [
  ...GENERATED_BUNDLE_NAMES,
  ...STATIC_ASSET_NAMES,
];

// Repository metadata may share the committed output directory, but build
// output may not add any other files or chunks.
export const OUTPUT_METADATA_NAMES = [".gitignore"];

// Stable global-API markers proving each bundle actually initialized the
// object Swift/HTML call into at runtime. These check source-level identifier
// names the runtime depends on (not minifier output shape), so they survive
// any minifier's variable renaming/whitespace choices.
export const GLOBAL_MARKERS = {
  "readium-reflowable.js": /globalThis\.readium\s*=/,
  "readium-fixed.js": /globalThis\.readium\s*=/,
  "readium-fixed-wrapper-one.js": /globalThis\.spread\s*=/,
  "readium-fixed-wrapper-two.js": /globalThis\.spread\s*=/,
  "readium-continuous-wrapper.js": /globalThis\.continuousWrapper\s*=/,
  "readium-continuous-wrapper-shim.js": /cw\.applyDecorations\s*=/,
};

const SCRIPTS_ROOT = path.resolve(__dirname, "..");

// Absolute, anchored at this module's own location rather than a caller's.
export const DEFAULT_OUT_DIR = path.resolve(
  SCRIPTS_ROOT,
  "../Assets/Static/scripts"
);

/**
 * Resolves an optional output override relative to the Scripts project root.
 * Every build/clean/verify caller must use this function so a relative
 * BUNDLE_OUT_DIR cannot point each phase at a different directory.
 * @param {string | undefined} requested
 */
export function resolveBundleOutDir(requested) {
  return requested ? path.resolve(SCRIPTS_ROOT, requested) : DEFAULT_OUT_DIR;
}
