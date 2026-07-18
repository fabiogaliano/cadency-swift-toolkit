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
  load `vite-plus-core` from the *parent's* `node_modules` and fail even
  though they pass standalone. Keep the shell boundary.

## Types

`tsconfig.json` is a strict, non-empty `tsc --noEmit` gate (`strict: true`,
`skipLibCheck: false` — it was silently masking broken declarations in our
own `src/types/*.d.ts`, not just dependency noise). TypeScript is pinned
exactly at `7.0.2` (no `^`).

Only Cadency-owned, behaviorally-tested leaf modules are converted, under
`src/cadency/continuous/` and `src/cadency/interaction/`. Upstream/vendor
JS is intentionally left untyped — narrow declaration seams
(`src/dom.d.ts`, `src/utils.d.ts`, `src/selection.d.ts`,
`src/types/webkit.d.ts`, `src/types/readium.d.ts`) declare only the
handful of exports/globals a typed module actually calls, never a whole
upstream file's surface. `src/index-continuous-wrapper.js` (1,400+ lines)
stays plain JS: a disposable `// @ts-check` probe against it measured 103
implicit-any/nullable-DOM errors, so `checkJs` stays `false` package-wide
and this file isn't included in the tsconfig program.

Type-aware lint (`lint.options.typeAware`/`typeCheck` in `vite.config.ts`)
stays disabled — it doesn't scope to `tsconfig.json`'s narrow `include`
list and reaches the whole package instead (confirmed empirically).
`tsc --noEmit` via `vp run typecheck` is the real, correctly-scoped gate.

Baselines as of the last engine-wide gate run: 80 tests across 7 files
(74 source + 6 bundle-verifier), 5 committed bundles, `vp check` clean
across 41 formatted / 37 linted files.
