import { toNativeRect } from "../../rect";
import { logError } from "../../utils";
import { TextRange } from "../../vendor/hypothesis/anchoring/text-range";
import { getCssSelector } from "css-selector-generator";

export interface LocalRangeRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ViewportRangeRect {
  width: number;
  height: number;
  left: number;
  top: number;
  right: number;
  bottom: number;
}

// Returns a Range spanning the full contents of `element`. Does not mutate
// the document.
export function rangeForElement(element: Element): Range {
  const range = document.createRange();
  range.selectNodeContents(element);
  return range;
}

// Collapses whitespace for emptiness/meaningfulness checks. The exact text
// sent to native code is left unnormalized so it matches `textContent`
// verbatim, which is what `TextQuoteAnchor` matches against.
export function normalizeHighlightText(text: string): string {
  return text.trim().replace(/\n/g, " ").replace(/\s\s+/g, " ");
}

// Generates a CSS selector anchored to `element`, suitable for
// `locations.cssSelector`.
export function cssSelectorForElement(element: Element): string | undefined {
  try {
    return getCssSelector(element);
  } catch (error) {
    logError(error);
    return undefined;
  }
}

// Rect for `onSelection`, in the coordinate space `toNativeRect` targets
// (FXL's `adjustPointToViewport`, which can add an outer document's scroll
// offset). Kept distinct from `rangeLocalRect` below on purpose: the two are
// not interchangeable, and silently swapping one for the other would corrupt
// whichever coordinate space the caller actually needs.
export function rangeViewportRect(range: Range): ViewportRangeRect | undefined {
  try {
    return toNativeRect(range.getBoundingClientRect());
  } catch (error) {
    logError(error);
    return undefined;
  }
}

// Rect for block activation, in the iframe's own local viewport coordinates
// - deliberately not run through `toNativeRect`/`adjustPointToViewport`,
// which assume the fixed-layout frame-nesting case and would also fold in
// the continuous wrapper's outer scroll offset. Converting this to top-level
// WKWebView coordinates (adding the iframe's own offset, but not outer
// scroll) is the caller's job.
export function rangeLocalRect(range: Range): LocalRangeRect | undefined {
  try {
    const { x, y, width, height } = range.getBoundingClientRect();
    return { x, y, width, height };
  } catch (error) {
    logError(error);
    return undefined;
  }
}

// Returns short before/after context around `range`, measured against the
// whole document body so it stays meaningful even when `range` covers an
// entire block (whose own text IS the quote, leaving nothing "before" or
// "after" within the block itself).
export function contextAroundRange(
  range: Range,
  snippetLength: number
): { before: string; after: string } {
  const fullText = document.body.textContent;
  if (fullText === null) {
    throw new Error("Document body did not expose text content");
  }
  const { start, end } = rangeTextOffsets(range);
  return textContextAround(fullText, start, end, snippetLength);
}

function rangeTextOffsets(range: Range): { start: number; end: number } {
  const textRange = TextRange.fromRange(range).relativeTo(document.body);
  return { start: textRange.start.offset, end: textRange.end.offset };
}

// Ignores the first/last "word" of the captured window, since it may be cut
// mid-word by the fixed snippet length.
function textContextAround(
  text: string,
  start: number,
  end: number,
  snippetLength: number
): { before: string; after: string } {
  let before = text.slice(Math.max(0, start - snippetLength), start);
  const firstWordStart = before.search(/\P{L}\p{L}/gu);
  if (firstWordStart !== -1) {
    before = before.slice(firstWordStart + 1);
  }

  let after = text.slice(end, Math.min(text.length, end + snippetLength));
  const lastWordEnd = Array.from(after.matchAll(/\p{L}\P{L}/gu)).pop();
  if (lastWordEnd !== undefined && lastWordEnd.index > 1) {
    after = after.slice(0, lastWordEnd.index + 1);
  }

  return { before, after };
}
