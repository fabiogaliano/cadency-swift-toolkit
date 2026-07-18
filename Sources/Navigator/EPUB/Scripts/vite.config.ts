import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite-plus";
import { BUNDLE_MODES, DEFAULT_OUT_DIR } from "./scripts/bundle-manifest.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Vendored upstream sources are not ours to lint or reformat.
const vendored = ["src/vendor/**", "**/node_modules/**"];

const BUNDLE_MODE_NAMES = Object.keys(BUNDLE_MODES);

// The disposable-directory override the Step 2 rehearsal (and the bundle
// verifier) point at instead of the committed Assets/Static/scripts, so a
// rehearsal build can never touch the real artifacts.
function resolveBundleOutDir() {
  return path.resolve(__dirname, process.env.BUNDLE_OUT_DIR || DEFAULT_OUT_DIR);
}

// One closed mode -> entry map, five single-input production builds. There is
// no default entry: an absent/unknown mode (including a bare `vp build`,
// which defaults mode to "production") must fail loudly instead of silently
// building one bundle — see the `bundle` task below for the supported way to
// build all five.
function bundleBuildConfig(mode) {
  const entry = BUNDLE_MODES[mode];
  if (!entry) {
    throw new Error(
      `Unknown or missing build mode "${mode}". The engine bundle has no ` +
        `default entry - run \`vp run bundle\` to build all five, or ` +
        `\`vp build --mode <mode>\` with one of: ${BUNDLE_MODE_NAMES.join(", ")}.`
    );
  }

  return {
    build: {
      outDir: resolveBundleOutDir(),
      // The five modes share one output directory; each build must not wipe
      // the other four bundles that already landed there.
      emptyOutDir: false,
      sourcemap: true,
      minify: true,
      target: "safari15",
      rollupOptions: {
        input: path.resolve(__dirname, entry),
        output: {
          // Rolldown's `format` is a literal-string union (`ModuleFormat`),
          // not `string`. Without `as const` this object literal's return
          // widens through `bundleBuildConfig`'s inferred return type, so
          // "iife" becomes plain `string` and stops satisfying Vite's
          // `UserConfig["build"]["rollupOptions"]["output"]` type.
          format: "iife" as const,
          entryFileNames: `readium-${mode}.js`,
          // iife has no notion of multiple chunks; say so explicitly rather
          // than relying on Rolldown's format-implied default.
          codeSplitting: false,
        },
      },
    },
    // Source uses `global.readium`/`global.spread`/`global.continuousWrapper`
    // (a Node/webpack-era global object). Rolldown does not polyfill it, so
    // without this define those assignments are dead references in WKWebView.
    define: {
      global: "globalThis",
    },
  };
}

export default defineConfig(({ command, mode }) => ({
  // vite-plus resolves this same config with command: "build", mode:
  // "development" purely to read the lint/fmt/test/run sections for `vp
  // check`/`vp lint`/`vp fmt` (confirmed by tracing its internal
  // resolveViteConfig probe) - that probe must not trip the unknown-mode
  // error above. A real `vp build` always passes an explicit --mode (one of
  // the five below) or defaults to "production", never "development".
  ...(command === "build" && mode !== "development"
    ? bundleBuildConfig(mode)
    : {}),

  lint: {
    ignorePatterns: vendored,
    env: {
      browser: true,
      es2021: true,
    },
    globals: {
      webkit: "readonly",
      global: "writable",
      readium: "writable",
    },
    options: {
      // A tsconfig.json exists now, but type-aware lint doesn't scope to its
      // narrow `include` list - enabling it (tested empirically) type-checks
      // vite.config.ts itself (implicit-any findings) and every untyped
      // tests/*.js file (e.g. floating-promise warnings in
      // pending-navigation.test.js) that Plan 006 hasn't touched yet. `tsc
      // --noEmit` via `vp run typecheck` is the real, correctly-scoped gate;
      // re-enable this only once type-aware lint can be pointed at just the
      // converted files.
      typeAware: false,
      typeCheck: false,
    },
    rules: {
      // Matches the ESLint baseline this replaces: `no-unused-vars` did not
      // check caught errors, and 13 upstream/Cadency catches rely on that.
      // Tightening it is a deliberate change, not migration collateral.
      "no-unused-vars": ["error", { caughtErrors: "none" }],
      // Not in the ESLint baseline this replaces. Its one site,
      // `...(window._cssProperties || {})`, is deliberate defensive style in
      // upstream-derived source — rewriting it is not this migration's job.
      "unicorn/no-useless-fallback-in-spread": "off",
    },
  },

  fmt: {
    ignorePatterns: vendored,
    printWidth: 80,
    trailingComma: "es5",
    sortPackageJson: false,
  },

  test: {
    include: ["tests/**/*.test.js", "tests/**/*.test.ts"],
  },

  run: {
    tasks: {
      // Never cached: it always cleans, always rebuilds, always re-verifies.
      // A stale cache hit here would silently skip regenerating a bundle.
      bundle: {
        cache: false,
        command: [
          "node scripts/clean-bundles.mjs",
          ...BUNDLE_MODE_NAMES.map((name) => `vp build --mode ${name}`),
          "node scripts/verify-bundles.mjs",
        ],
      },
    },
  },
}));
