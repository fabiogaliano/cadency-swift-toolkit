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

// Hand-authored static assets that permanently live in the bundle output
// directory alongside the five generated IIFEs. `readium-continuous-wrapper-shim.js`
// is loaded directly by WrapperPreparationEngine.swift by filename; it has no
// src/ entry and is never produced by a bundler, so it is excluded from both
// the verifier's exact-file check and the cleaner's deletion pass.
export const STATIC_ASSET_NAMES = ["readium-continuous-wrapper-shim.js"];

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
};

// Absolute, anchored at this module's own location rather than a bare
// relative string. verify-bundles.mjs/clean-bundles.mjs live in Scripts/scripts/
// but vite.config.ts lives one directory up in Scripts/; a relative string
// here previously got resolved against *each caller's own* __dirname, so
// vite.config.ts silently wrote every build one directory too high (into a
// stray sibling of EPUB/, not EPUB/Assets/Static/scripts). Being absolute
// makes path.resolve(callerDir, DEFAULT_OUT_DIR) return this same path no
// matter which file combines it with its own __dirname.
export const DEFAULT_OUT_DIR = path.resolve(
  __dirname,
  "../../Assets/Static/scripts"
);
