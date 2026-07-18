// Narrow declaration seam for `selection.js` (Plan 006 Step 4) - declares
// only the five range/text-context helpers `blocks.ts` calls (the shared
// machinery `selection.js`'s own comment says backs both plain-text
// selection and block activation), not the whole upstream-heavy file.

// Returns a Range spanning the full contents of `element`. Does not mutate
// the document.
export declare function rangeForElement(element: Element): Range;

// Collapses whitespace for emptiness/meaningfulness checks.
export declare function normalizeHighlightText(text: string): string;

// Generates a CSS selector anchored to `element`. `undefined` on the
// generator's own internal failure (caught and logged inside `selection.js`
// itself), never `null` - matches the real catch-and-return-undefined path.
export declare function cssSelectorForElement(
  element: Element
): string | undefined;

// Rect for block activation, in the iframe's own local viewport coordinates.
// `undefined` on the same caught-and-logged failure path as
// `cssSelectorForElement`.
export declare function rangeLocalRect(
  range: Range
): { x: number; y: number; width: number; height: number } | undefined;

// Short before/after text context around `range`, measured against the
// whole document body.
export declare function contextAroundRange(
  range: Range,
  snippetLength: number
): { before: string; after: string };
