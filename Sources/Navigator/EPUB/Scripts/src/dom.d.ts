// Narrow declaration seam for `dom.js`, an otherwise-untyped upstream-heavy
// module (Plan 006 Step 4). This is NOT a full type surface for `dom.js` -
// it declares only the one export a typed Cadency module (`blocks.ts`)
// actually calls. Every other export of `dom.js` remains untyped/unchecked;
// converting or fully annotating that file is explicitly out of this plan's
// scope.

// Matches `dom.js`'s real recursive walk: starts from `element` itself
// (inclusive) and returns the nearest ancestor-or-self considered "user
// interactive" (a link, control, editable region, embedded media), or null
// if none is found by the time it reaches the document root.
export declare function findNearestInteractiveAncestor(
  element: Element | null
): Element | null;
