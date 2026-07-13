//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import { log as logNative, logError } from "./utils";
import { toNativeRect } from "./rect";
import { TextRange } from "./vendor/hypothesis/anchoring/text-range";
import { getCssSelector } from "css-selector-generator";

// Polyfill for iOS 12
import matchAll from "string.prototype.matchall";
matchAll.shim();

const debug = true;

// Selections can span multiple sentences, so this stays generous.
const SELECTION_CONTEXT_LENGTH = 200;

export function getCurrentSelection() {
  if (!readium.link) {
    return null;
  }
  const href = readium.link.href;
  if (!href) {
    return null;
  }

  const range = resolveCurrentSelectionRange();
  if (!range) {
    return null;
  }

  const highlight = range.toString();
  if (normalizeHighlightText(highlight).length === 0) {
    return null;
  }

  const payload = {
    href,
    type: "application/xhtml+xml",
    text: {
      highlight,
      ...contextAroundRange(range, SELECTION_CONTEXT_LENGTH),
    },
    rect: rangeViewportRect(range),
  };

  // Anchor the Locator to the element that actually contains the selection,
  // instead of leaving it to whatever `currentLocation` happens to be (the
  // reading position, which may be a different, non-containing element). This
  // is what lets `rangeFromLocator` resolve the highlight reliably later on.
  const container = containingElementForRange(range);
  const cssSelector = container && cssSelectorForElement(container);
  if (cssSelector) {
    payload.locations = { cssSelector };
  }

  return payload;
}

// Resolves the current, non-collapsed window selection into a single ordered
// Range, tolerating WebKit occasionally reporting anchor/focus in reverse of
// document order.
function resolveCurrentSelectionRange() {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed) {
    return undefined;
  }
  if (!selection.anchorNode || !selection.focusNode) {
    return undefined;
  }

  const range =
    selection.rangeCount === 1
      ? selection.getRangeAt(0)
      : createOrderedRange(
          selection.anchorNode,
          selection.anchorOffset,
          selection.focusNode,
          selection.focusOffset
        );
  if (!range || range.collapsed) {
    log("$$$$$$$$$$$$$$$$$ CANNOT GET NON-COLLAPSED SELECTION RANGE?!");
    return undefined;
  }
  return range;
}

function containingElementForRange(range) {
  const container = range.commonAncestorContainer;
  return container.nodeType === Node.ELEMENT_NODE
    ? container
    : container.parentElement;
}

function createOrderedRange(startNode, startOffset, endNode, endOffset) {
  const range = new Range();
  range.setStart(startNode, startOffset);
  range.setEnd(endNode, endOffset);
  if (!range.collapsed) {
    return range;
  }
  log(">>> createOrderedRange COLLAPSED ... RANGE REVERSE?");
  const rangeReverse = new Range();
  rangeReverse.setStart(endNode, endOffset);
  rangeReverse.setEnd(startNode, startOffset);
  if (!rangeReverse.collapsed) {
    log(">>> createOrderedRange RANGE REVERSE OK.");
    return rangeReverse;
  }
  log(">>> createOrderedRange RANGE REVERSE ALSO COLLAPSED?!");
  return undefined;
}

export function convertRangeInfo(document, rangeInfo) {
  const startElement = document.querySelector(
    rangeInfo.startContainerElementCssSelector
  );
  if (!startElement) {
    log("^^^ convertRangeInfo NO START ELEMENT CSS SELECTOR?!");
    return undefined;
  }
  let startContainer = startElement;
  if (rangeInfo.startContainerChildTextNodeIndex >= 0) {
    if (
      rangeInfo.startContainerChildTextNodeIndex >=
      startElement.childNodes.length
    ) {
      log(
        "^^^ convertRangeInfo rangeInfo.startContainerChildTextNodeIndex >= startElement.childNodes.length?!"
      );
      return undefined;
    }
    startContainer =
      startElement.childNodes[rangeInfo.startContainerChildTextNodeIndex];
    if (startContainer.nodeType !== Node.TEXT_NODE) {
      log("^^^ convertRangeInfo startContainer.nodeType !== Node.TEXT_NODE?!");
      return undefined;
    }
  }
  const endElement = document.querySelector(
    rangeInfo.endContainerElementCssSelector
  );
  if (!endElement) {
    log("^^^ convertRangeInfo NO END ELEMENT CSS SELECTOR?!");
    return undefined;
  }
  let endContainer = endElement;
  if (rangeInfo.endContainerChildTextNodeIndex >= 0) {
    if (
      rangeInfo.endContainerChildTextNodeIndex >= endElement.childNodes.length
    ) {
      log(
        "^^^ convertRangeInfo rangeInfo.endContainerChildTextNodeIndex >= endElement.childNodes.length?!"
      );
      return undefined;
    }
    endContainer =
      endElement.childNodes[rangeInfo.endContainerChildTextNodeIndex];
    if (endContainer.nodeType !== Node.TEXT_NODE) {
      log("^^^ convertRangeInfo endContainer.nodeType !== Node.TEXT_NODE?!");
      return undefined;
    }
  }
  return createOrderedRange(
    startContainer,
    rangeInfo.startOffset,
    endContainer,
    rangeInfo.endOffset
  );
}

export function location2RangeInfo(location) {
  const locations = location.locations;
  const domRange = locations.domRange;
  const start = domRange.start;
  const end = domRange.end;

  return {
    endContainerChildTextNodeIndex: end.textNodeIndex,
    endContainerElementCssSelector: end.cssSelector,
    endOffset: end.offset,
    startContainerChildTextNodeIndex: start.textNodeIndex,
    startContainerElementCssSelector: start.cssSelector,
    startOffset: start.offset,
  };
}

/// Shared range and text-context machinery.
///
/// These helpers back both plain text selection (above) and block activation
/// (`blocks.js`), so the two build Locators the exact same way instead of
/// each reimplementing range construction, text normalization, and context
/// extraction.

// Returns a Range spanning the full contents of `element`. Does not mutate
// the document.
export function rangeForElement(element) {
  const range = document.createRange();
  range.selectNodeContents(element);
  return range;
}

// Collapses whitespace for emptiness/meaningfulness checks. The exact text
// sent to native code is left unnormalized so it matches `textContent`
// verbatim, which is what `TextQuoteAnchor` matches against.
export function normalizeHighlightText(text) {
  return text.trim().replace(/\n/g, " ").replace(/\s\s+/g, " ");
}

// Generates a CSS selector anchored to `element`, suitable for
// `locations.cssSelector`.
export function cssSelectorForElement(element) {
  try {
    return getCssSelector(element);
  } catch (e) {
    logError(e);
    return undefined;
  }
}

// Rect for `onSelection`, in the coordinate space `toNativeRect` targets
// (FXL's `adjustPointToViewport`, which can add an outer document's scroll
// offset). Kept distinct from `rangeLocalRect` below on purpose: the two are
// not interchangeable, and silently swapping one for the other would corrupt
// whichever coordinate space the caller actually needs.
export function rangeViewportRect(range) {
  try {
    return toNativeRect(range.getBoundingClientRect());
  } catch (e) {
    logError(e);
    return undefined;
  }
}

// Rect for block activation, in the iframe's own local viewport coordinates
// - deliberately *not* run through `toNativeRect`/`adjustPointToViewport`,
// which assume the fixed-layout frame-nesting case and would also fold in
// the continuous wrapper's outer scroll offset. Converting this to top-level
// WKWebView coordinates (adding the iframe's own offset, but not outer
// scroll) is the caller's job.
export function rangeLocalRect(range) {
  try {
    const { x, y, width, height } = range.getBoundingClientRect();
    return { x, y, width, height };
  } catch (e) {
    logError(e);
    return undefined;
  }
}

// Returns short before/after context around `range`, measured against the
// whole document body so it stays meaningful even when `range` covers an
// entire block (whose own text IS the quote, leaving nothing "before" or
// "after" within the block itself).
export function contextAroundRange(range, snippetLength) {
  const fullText = document.body.textContent;
  const { start, end } = rangeTextOffsets(range);
  return textContextAround(fullText, start, end, snippetLength);
}

function rangeTextOffsets(range) {
  const textRange = TextRange.fromRange(range).relativeTo(document.body);
  return { start: textRange.start.offset, end: textRange.end.offset };
}

// Ignores the first/last "word" of the captured window, since it may be cut
// mid-word by the fixed snippet length.
function textContextAround(text, start, end, snippetLength) {
  let before = text.slice(Math.max(0, start - snippetLength), start);
  let firstWordStart = before.search(/\P{L}\p{L}/gu);
  if (firstWordStart !== -1) {
    before = before.slice(firstWordStart + 1);
  }

  let after = text.slice(end, Math.min(text.length, end + snippetLength));
  let lastWordEnd = Array.from(after.matchAll(/\p{L}\P{L}/gu)).pop();
  if (lastWordEnd !== undefined && lastWordEnd.index > 1) {
    after = after.slice(0, lastWordEnd.index + 1);
  }

  return { before, after };
}

function log() {
  if (debug) {
    logNative.apply(null, arguments);
  }
}
