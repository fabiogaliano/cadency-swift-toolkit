// Ambient JSON-boundary types for Readium/Cadency payloads that cross an
// untyped seam (native bridge, the `readium` chapter-API global, decoration
// groups, ...). Kept deliberately narrow per Plan 006 Step 2:
//
// - Most of the `readium` chapter-API object's methods
//   (`scrollToId`, `activateBlockAtLocalPoint`, `registerDecorationTemplates`,
//   `getDecorations`, ...) are still intentionally NOT declared here. Several
//   return opaque, non-JSON runtime objects (e.g. `getDecorations` returns an
//   internal `DecorationGroup` instance built in src/decorator.js) that would
//   have to be guessed at rather than proven against a real typed call site -
//   exactly what this step forbids. `link` is the one exception (Plan 006
//   Step 4): `blocks.ts`'s `buildBlockLocator` reads `readium.link.href` (the
//   publication-relative chapter href, assigned once per chapter mount by
//   `index-continuous-wrapper.js`'s `readium.link = item.link || { href:
//   item.href }` and by the fixed-layout wrapper's injected `readium.link =
//   JSON.stringify(resource.link)`). Both assignments always include at least
//   `href`, so that's all that's declared - the rest of any richer `Link`
//   object is left unmodeled since nothing typed reads it. The remaining
//   surface is deferred until a typed caller actually needs it.
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

// The `readium` chapter-API global (`global.readium = {...}` in index.js,
// with `.link` assigned separately per chapter mount). `link` is optional
// because a chapter's own script can run before its mount code has set it.
interface ReadiumChapterLink {
  href: string;
}

declare const readium: {
  link?: ReadiumChapterLink;
  /** Set only by the continuous wrapper's subframe bootstrap. */
  isContinuousReader?: boolean;
};
