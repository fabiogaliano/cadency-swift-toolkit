# Readium JS (Swift)

A set of JavaScript/TypeScript files used by the Swift EPUB navigator.

## Toolchain

Vite+ owns checks, tests, and bundling. This directory is its own project
root — `pnpm-workspace.yaml` anchors it so pnpm doesn't walk up and install
the parent `cadency-world` workspace instead. Don't delete that file, and
don't add this package to the parent's `pnpm-workspace.yaml`.

Run every command below **from this directory**, not via the parent.

```sh
CI=true command vp install --frozen-lockfile   # vp install is interactive by default
command vp check                               # fmt + lint, NOT a type checker
command vp run typecheck                       # tsc --noEmit, the real TS gate
command vp test                                # Vitest
command vp run bundle                          # clean, rebuild all 5 modes, verify
git diff --exit-code -- ../Assets/Static/scripts/*.js   # from repo root: confirm no drift
```

Gotchas:

- `vp` is a shell function in most agent environments — use `command vp` in
  scripts so it resolves to the real binary.
- `CI=true` also forces `--frozen-lockfile`; pass `--no-frozen-lockfile`
  explicitly when you actually intend to refresh the lock.
- The parent has no `engine:verify` task on purpose — driving this package
  from a parent Vite Task leaks the parent's module resolution in, so tests
  load `vite-plus-core` from the _parent's_ `node_modules` and fail even
  though they pass standalone. Keep the shell boundary.

## Types

`tsconfig.json` is a strict, non-empty `tsc --noEmit` source gate (`strict:
true`, `skipLibCheck: false` — it was silently masking broken declarations in
our own `src/types/*.d.ts`, not just dependency noise). `tsconfig.tooling.json`
separately checks `vite.config.ts` and the bundle manifest; it skips dependency
declarations because Vite+ publishes references to optional pack/devtools peers
this package does not install. `vp run typecheck` runs both gates. TypeScript is
pinned exactly at `7.0.2` (no `^`).

Cadency-owned state, policy, payload construction, and interaction helpers live
as strict TypeScript under `src/cadency/continuous/` and
`src/cadency/interaction/`. Upstream-compatible JavaScript files remain thin
DOM, event-registration, and native-bridge adapters. Narrow declaration seams
(`src/rect.d.ts`, `src/utils.d.ts`, `src/types/webkit.d.ts`, and
`src/types/readium.d.ts`) cover only exports and globals used by real typed call
sites; upstream and vendor JavaScript remains unchecked.

`src/index-continuous-wrapper.js` and `src/gestures.js` intentionally remain
JavaScript to preserve upstream mergeability and effect wiring. A disposable
strict `// @ts-check` probe after the policy extraction measured 98 diagnostics
in the continuous wrapper and 17 in gestures. The probe was reverted;
`checkJs` remains `false` package-wide.

Type-aware lint (`lint.options.typeAware`/`typeCheck` in `vite.config.ts`)
stays disabled — it doesn't scope to `tsconfig.json`'s narrow `include`
list and reaches the whole package instead (confirmed empirically).
`tsc --noEmit` via `vp run typecheck` is the real, correctly-scoped gate.

Current baseline: 120 tests across 15 files, 5 committed bundles with 5
generated source maps, and clean formatting, lint, and strict typecheck gates.
Targeted live-WKWebView coverage executes fixed, fixed-wrapper, reflowable
selection, continuous navigation/decoration, hostile-EPUB, and block-activation
paths from committed bundles.
