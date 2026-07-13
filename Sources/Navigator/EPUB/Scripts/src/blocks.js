//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// Semantic block detection and Locator generation for double-tap block
// highlighting. This module only resolves blocks and builds the payload a
// future gesture handler would send natively - it does not listen for
// gestures or touch the WK message bridge itself.

import { findNearestInteractiveAncestor } from "./dom";
import { logError, logErrorMessage } from "./utils";
import {
  cssSelectorForElement,
  contextAroundRange,
  normalizeHighlightText,
  rangeForElement,
  rangeLocalRect,
} from "./selection";

// Elements treated as a complete, independently-activatable reading block.
const PRIMARY_BLOCK_TAGS = new Set([
  "p",
  "li",
  "blockquote",
  "pre",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "figcaption",
  "dt",
  "dd",
]);

// Never treated as a leaf block by the div-based fallback, regardless of
// their computed display.
const FALLBACK_REJECTED_TAGS = new Set([
  "body",
  "html",
  "nav",
  "form",
  "audio",
  "video",
  "canvas",
  "picture",
  "svg",
  "iframe",
  "object",
  "embed",
]);

// Computed `display` values considered "block-like" for the conservative
// div-based fallback.
const FALLBACK_BLOCK_DISPLAY = new Set([
  "block",
  "list-item",
  "flex",
  "grid",
  "table",
  "table-row",
  "table-cell",
  "table-row-group",
]);

// Short, since a block's own text already provides the bulk of the context.
const BLOCK_CONTEXT_LENGTH = 50;

/**
 * Resolves the semantic block a pointer/tap event target belongs to.
 *
 * Returns the block Element, or null if the target is empty/hidden/inert,
 * sits inside interactive content, or no reasonable block can be found
 * (never activates the whole chapter).
 */
export function resolveSemanticBlockForTarget(target) {
  try {
    const element = elementFromEventTarget(target);
    if (!element) {
      return null;
    }

    // A tap anywhere inside interactive content (a link, a button, an <em>
    // inside an <a>, ...) never activates a block, even if it also happens
    // to sit inside a paragraph.
    if (findNearestInteractiveAncestor(element)) {
      return null;
    }

    return (
      findNearestPrimaryBlock(element) || findNearestLeafBlockFallback(element)
    );
  } catch (e) {
    // Callers resolve this on every candidate tap; prefer no activation over
    // letting a resolution failure propagate into gesture arbitration.
    logError(e);
    return null;
  }
}

/**
 * Convenience wrapper around `resolveSemanticBlockForTarget` for callers that
 * only have a viewport point (e.g. a confirmed double-tap position) rather
 * than a DOM event target.
 */
export function resolveSemanticBlockAtPoint(x, y) {
  return resolveSemanticBlockForTarget(document.elementFromPoint(x, y));
}

/**
 * Builds the Readium Locator for an activated block: chapter href, XHTML
 * type, a CSS selector anchored to the block, and the exact text plus short
 * before/after context needed for `TextQuoteAnchor` (via `rangeFromLocator`).
 *
 * Returns null rather than a best-effort/partial Locator - block activation
 * should fail silently over highlighting the wrong text.
 */
export function buildBlockLocator(blockElement) {
  try {
    if (!blockElement) {
      return null;
    }

    const href = readium && readium.link && readium.link.href;
    if (!href) {
      return null;
    }

    const exact = blockElement.textContent;
    if (normalizeHighlightText(exact).length === 0) {
      return null;
    }

    const cssSelector = cssSelectorForElement(blockElement);
    if (!cssSelector) {
      return null;
    }
    // A selector that doesn't resolve back to the exact tapped element can't
    // be trusted to scope `TextQuoteAnchor` correctly later - bail out
    // rather than risk highlighting a different block.
    if (document.querySelector(cssSelector) !== blockElement) {
      logErrorMessage(
        "blocks: generated cssSelector did not resolve back to the tapped block"
      );
      return null;
    }

    const range = rangeForElement(blockElement);
    const { before, after } = contextAroundRange(range, BLOCK_CONTEXT_LENGTH);

    return {
      href,
      type: "application/xhtml+xml",
      locations: { cssSelector },
      text: { highlight: exact, before, after },
    };
  } catch (e) {
    logError(e);
    return null;
  }
}

/**
 * Builds the full activation payload for a block: its Locator, the range's
 * rectangle in the chapter iframe's own local viewport coordinates (named
 * `iframeRect`, not `rect`, precisely because it is *not* yet in top-level
 * WKWebView coordinates - the caller must add the iframe's own offset before
 * emitting it natively), and a transient, deterministic `blockKey` for
 * toggle behavior.
 *
 * Returns null if a valid Locator or a sane rect can't be produced.
 */
export function buildBlockActivationPayload(blockElement) {
  try {
    const locator = buildBlockLocator(blockElement);
    if (!locator) {
      return null;
    }

    const range = rangeForElement(blockElement);
    const iframeRect = rangeLocalRect(range);
    if (!iframeRect || !isSaneRect(iframeRect)) {
      return null;
    }

    return {
      locator,
      iframeRect,
      blockKey: buildBlockKey(
        locator.href,
        locator.locations.cssSelector,
        locator.text.highlight
      ),
    };
  } catch (e) {
    logError(e);
    return null;
  }
}

function isSaneRect(rect) {
  return (
    Number.isFinite(rect.x) &&
    Number.isFinite(rect.y) &&
    Number.isFinite(rect.width) &&
    Number.isFinite(rect.height) &&
    rect.width > 0 &&
    rect.height > 0
  );
}

function elementFromEventTarget(target) {
  if (!target) {
    return null;
  }
  if (target.nodeType === Node.TEXT_NODE) {
    return target.parentElement;
  }
  if (target.nodeType === Node.ELEMENT_NODE) {
    return target;
  }
  return null;
}

// Walks up from `element` and returns the nearest ancestor-or-self primary
// block that is non-empty, visible, and not inert. Starting from the tap
// target and walking outward is what makes a nested primary block (e.g. the
// <p> in an <li> > <p>) win over its containing primary parent - it's simply
// found first.
function findNearestPrimaryBlock(element) {
  let node = element;
  while (node && node.nodeType === Node.ELEMENT_NODE) {
    if (
      PRIMARY_BLOCK_TAGS.has(node.nodeName.toLowerCase()) &&
      isEligibleBlock(node)
    ) {
      return node;
    }
    node = node.parentElement;
  }
  return null;
}

function isEligibleBlock(element) {
  return (
    !isHiddenOrInert(element) &&
    normalizeHighlightText(element.textContent).length > 0
  );
}

// Conservative fallback for malformed or div-based EPUBs with no semantic
// primary blocks. Prefers no activation over highlighting an entire chapter.
function findNearestLeafBlockFallback(element) {
  let node = element;
  while (node && node.nodeType === Node.ELEMENT_NODE) {
    if (isConservativeLeafBlockCandidate(node)) {
      return node;
    }
    node = node.parentElement;
  }
  return null;
}

function isConservativeLeafBlockCandidate(element) {
  const tag = element.nodeName.toLowerCase();
  if (FALLBACK_REJECTED_TAGS.has(tag)) {
    return false;
  }
  if (element.getAttribute && element.getAttribute("role") === "navigation") {
    return false;
  }
  if (isHiddenOrInert(element)) {
    return false;
  }
  if (findNearestInteractiveAncestor(element)) {
    return false;
  }

  const style = getComputedStyle(element);
  if (!style || !FALLBACK_BLOCK_DISPLAY.has(style.display)) {
    return false;
  }
  if (normalizeHighlightText(element.textContent).length === 0) {
    return false;
  }
  // A container wrapping several meaningful block-like children is a
  // section, not a leaf - reject it so we never highlight an entire chapter.
  if (hasMultipleMeaningfulBlockDescendants(element)) {
    return false;
  }

  return true;
}

function hasMultipleMeaningfulBlockDescendants(element) {
  let meaningfulCount = 0;
  for (const descendant of element.querySelectorAll("*")) {
    const style = getComputedStyle(descendant);
    if (!style || !FALLBACK_BLOCK_DISPLAY.has(style.display)) {
      continue;
    }
    if (normalizeHighlightText(descendant.textContent).length === 0) {
      continue;
    }
    meaningfulCount++;
    if (meaningfulCount > 1) {
      return true;
    }
  }
  return false;
}

function isHiddenOrInert(element) {
  let node = element;
  while (node && node.nodeType === Node.ELEMENT_NODE) {
    if (node.hasAttribute("inert") || node.hasAttribute("hidden")) {
      return true;
    }
    const style = getComputedStyle(node);
    if (style) {
      if (style.display === "none") {
        return true;
      }
      if (style.visibility === "hidden" || style.visibility === "collapse") {
        return true;
      }
      if (parseFloat(style.opacity) === 0) {
        return true;
      }
    }
    node = node.parentElement;
  }
  return false;
}

// Derives a transient, deterministic identity for toggle behavior - never a
// durable block ID, and never random. The href is normalized so the same
// selector in different chapters produces different keys, and a short text
// fingerprint is appended in case a malformed document produces two elements
// that resolve to indistinguishable selectors.
function buildBlockKey(href, cssSelector, exactText) {
  return `${normalizeHref(href)}#${cssSelector}::${shortTextFingerprint(
    exactText
  )}`;
}

// `href` is already the publication-relative chapter identifier Swift
// matches against the reading order (`readium.link.href`, set once per
// chapter mount) - deliberately not re-resolved against the iframe's own
// document URL via `new URL()`, since that risks doubling path segments
// when the href and the iframe's base URL share a directory prefix. Just
// strip whitespace and any incidental query/hash.
function normalizeHref(href) {
  return href.trim().split(/[?#]/)[0];
}

// Deterministic (FNV-1a), short, and stable across calls for the same text -
// not a random or session-scoped value.
function shortTextFingerprint(text) {
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(36);
}
