import { defineConfig } from "vite-plus";

// Vendored upstream sources are not ours to lint or reformat.
const vendored = ["src/vendor/**", "**/node_modules/**"];

export default defineConfig({
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
      // Plan 006 supplies a real tsconfig; until then there is nothing for the
      // type-aware path to read.
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
    include: ["tests/**/*.test.js"],
  },
});
