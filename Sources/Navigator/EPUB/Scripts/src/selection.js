//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import { log as logNative } from "./utils";
import {
  contextAroundRange,
  cssSelectorForElement,
  normalizeHighlightText,
  rangeViewportRect,
} from "./cadency/interaction/selection-range";

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

function log() {
  if (debug) {
    logNative.apply(null, arguments);
  }
}
