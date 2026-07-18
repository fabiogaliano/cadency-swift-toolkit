// Ambient JSON-boundary types for Readium/Cadency payloads that cross an
// untyped seam (native bridge, the `readium` chapter-API global, decoration
// groups, ...). Kept deliberately narrow per Plan 006 Step 2:
//
// - No typed Cadency module calls the `readium` chapter-API object yet
//   (visible-locator.ts is pure geometry and never touches it), so its
//   methods (`scrollToId`, `activateBlockAtLocalPoint`,
//   `registerDecorationTemplates`, `getDecorations`, ...) are intentionally
//   NOT declared here. Several return opaque, non-JSON runtime objects (e.g.
//   `getDecorations` returns an internal `DecorationGroup` instance built in
//   src/decorator.js) that would have to be guessed at rather than proven
//   against a real typed call site - exactly what this step forbids.
//   Steps 3-4 (out of scope for this pass) add the chapter-API and
//   continuous-wrapper declarations once a typed module actually calls them.
// - `JSONValue` and `LocatorJSON` below ARE grounded in real source: the
//   recursive JSON shape is the only one safe to pass across
//   `postMessage`/global-object boundaries, and `LocatorJSON`'s fields match
//   what `dom.js`'s `findFirstVisibleLocator` actually constructs
//   (`{href, type, locations, text}`), which is the JSON Locator model at
//   https://readium.org/architecture/models/locators/.
//
// Both types are opaque by construction: a `JSONValue` cannot be indexed or
// called without first narrowing/validating it, so a caller must promote it
// to a concrete shape at the boundary rather than trusting it implicitly.
// Native Swift DTO validation remains the runtime authority; these types
// never replace it.

type JSONValue =
  | string
  | number
  | boolean
  | null
  | JSONValue[]
  | { [key: string]: JSONValue };

interface LocatorJSON {
  href: string;
  type: string;
  title?: string;
  locations?: { [key: string]: JSONValue };
  text?: { [key: string]: JSONValue };
}
