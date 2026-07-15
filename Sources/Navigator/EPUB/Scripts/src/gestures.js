//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import { findDecorationTarget, handleDecorationClickEvent } from "./decorator";
import { adjustPointToViewport, toTopViewportRect } from "./rect";
import { findNearestInteractiveElement } from "./dom";
import {
  resolveSemanticBlockAtPoint,
  resolveSemanticBlockForTarget,
  buildBlockActivationPayload,
} from "./blocks";
import { createTapArbiter } from "./tap-arbitration";
import { logError } from "./utils";
import { getCssSelector } from "css-selector-generator";

let isSelecting = false;

// All tap/double-tap/scroll/selection race logic lives in the arbiter
// (`tap-arbitration.js`); this file only adapts DOM events into it and
// carries out its decisions.
const tapArbiter = createTapArbiter({
  sendTap,
  isSelectionCollapsed: () => getSelection().isCollapsed,
});

window.addEventListener("DOMContentLoaded", function () {
  document.addEventListener("click", onClick, false);
  document.addEventListener("pointerdown", onPointerDown, false);
  document.addEventListener("pointerup", onPointerUp, false);
  document.addEventListener("pointermove", onPointerMove, false);
  document.addEventListener("pointercancel", onPointerCancel, false);

  document.addEventListener("selectionchange", function () {
    const selection = window.getSelection();
    isSelecting = selection != null && !selection.isCollapsed;
  });

  observeOuterScrollForCancellation();
});

// Timers must not survive iframe unload - `pagehide` fires reliably when the
// continuous wrapper replaces this chapter's iframe with a spacer (which
// tears down this document), and also covers plain navigation-away. `unload`
// is kept as a belt-and-suspenders fallback for older WebKit.
window.addEventListener("pagehide", onIframeTornDown);
window.addEventListener("unload", onIframeTornDown);

function onIframeTornDown() {
  tapArbiter.dispose();
  try {
    outerScrollTarget().removeEventListener("scroll", onOuterScroll);
  } catch (e) {
    // Parent already gone/inaccessible - nothing left to detach.
  }
}

function buildClickEvent(event) {
  const point = adjustPointToViewport({ x: event.clientX, y: event.clientY });
  return {
    defaultPrevented: event.defaultPrevented,
    x: point.x,
    y: point.y,
    targetElement: event.target.outerHTML,
    interactiveElement: findNearestInteractiveElement(event.target),
  };
}

function onClick(event) {
  if (tapArbiter.shouldSuppressClick()) {
    return;
  }

  if (readium.isFixedLayout) {
    // Double-tap arbitration is reflowable-only (plan section 6 is scoped to
    // reflowable content). Fixed layout keeps the pre-arbitration behavior:
    // plain, immediate tap forwarding, no delay, no `blockActivated`.
    if (!getSelection().isCollapsed) {
      return;
    }
    const clickEvent = buildClickEvent(event);
    if (handleDecorationClickEvent(event, clickEvent)) {
      return;
    }
    sendTap(clickEvent);
    return;
  }

  if (!getSelection().isCollapsed) {
    if (tapArbiter.hasPendingTap()) {
      const clickEvent = buildClickEvent(event);
      if (handleDecorationClickEvent(event, clickEvent)) {
        return;
      }
      const outcome = tapArbiter.tapDuringSelection({
        clickEvent,
        resolveBlock: () => resolveSemanticBlockForTarget(event.target),
      });
      if (outcome === "paired") {
        // Mark the synthesized click handled through the public DOM event
        // contract to keep WebKit's unhandled-double-tap smart-magnification
        // fallback away.
        event.preventDefault();
        return;
      }
    }
    // A genuine pre-existing (or long-press) selection: the tap will
    // dismiss it, so we don't forward it. Any pending arbitration belongs
    // to an earlier legitimate tap that simply failed to pair with this
    // one, so flush it (emitting its tap once, in order) instead of
    // silently swallowing it.
    tapArbiter.flushPendingTap();
    return;
  }

  const clickEvent = buildClickEvent(event);

  if (handleDecorationClickEvent(event, clickEvent)) {
    return;
  }

  const outcome = tapArbiter.tap({
    clickEvent,
    resolveBlock: () => resolveSemanticBlockForTarget(event.target),
  });
  if (outcome !== "forwarded") {
    event.preventDefault();
  }

  // We don't want to disable the default WebView behavior as it breaks some features without bringing any value.
  // event.stopPropagation();
  // event.preventDefault();
}

function sendTap(clickEvent) {
  // Send the tap data over the JS bridge even if it's been handled
  // within the webview, so that it can be preserved and used
  // by the WKNavigationDelegate if needed.
  webkit.messageHandlers.tap.postMessage(clickEvent);
}

// Entry point for the native, public-API double-tap recognizer, called via the
// continuous wrapper. "Local" = this chapter iframe's own client coordinate
// space - the wrapper translates from top-viewport coordinates before calling.
export function activateBlockAtLocalPoint(iframeLocalX, iframeLocalY) {
  tapArbiter.nativeActivationRequested();
  return (
    activateBlock(resolveSemanticBlockAtPoint(iframeLocalX, iframeLocalY)) ||
    "none"
  );
}

// Attempts to report a block activation to native. Returns "posted" only once
// the `blockActivated` message has actually been posted, and false on any
// failure (no Locator/payload, an unusable rect, or a postMessage error).
function activateBlock(blockElement) {
  try {
    const payload = buildBlockActivationPayload(blockElement);
    if (!payload) {
      return false;
    }

    const topViewportRect = toTopViewportRect(payload.iframeLocalRect);
    if (!isFiniteNativeRect(topViewportRect)) {
      // Pre-check so a coordinate-conversion edge case never reaches Swift,
      // which strictly drops rects that aren't finite/positive anyway.
      return false;
    }

    webkit.messageHandlers.blockActivated.postMessage({
      locator: payload.locator,
      rect: topViewportRect,
      blockKey: payload.blockKey,
    });
    // Clear the accidental WebKit word selection only now that activation has
    // actually been reported - a failed activation leaves any selection intact.
    clearAccidentalWordSelection();
    return "posted";
  } catch (e) {
    logError(e);
    return false;
  }
}

function isFiniteNativeRect(rect) {
  return (
    rect != null &&
    Number.isFinite(rect.x) &&
    Number.isFinite(rect.y) &&
    Number.isFinite(rect.width) &&
    Number.isFinite(rect.height) &&
    rect.width > 0 &&
    rect.height > 0
  );
}

// WebKit can select the word under the second tap as a side effect of the
// raw touch, independent of our own click-based arbitration. Clear it only
// now that we've confirmed this was a block-activating double tap - never
// proactively, so long-press selection and its handles are untouched.
//
// WebKit applies that side-effect selection on its own schedule - sometimes
// after the next frame - and a missed clear is costly: the stale selection
// makes the guard in `onClick` silently eat every subsequent tap. So instead
// of betting on one frame, keep clearing any selection that appears within a
// short window after the confirmed activation. The window is far shorter than
// a long-press, so a deliberate new selection can't get caught in it.
const ACCIDENTAL_SELECTION_CLEAR_WINDOW_MS = 300;

function clearAccidentalWordSelection() {
  const clearIfAny = () => {
    const selection = window.getSelection();
    if (selection && !selection.isCollapsed) {
      selection.removeAllRanges();
    }
  };
  document.addEventListener("selectionchange", clearIfAny);
  setTimeout(() => {
    document.removeEventListener("selectionchange", clearIfAny);
  }, ACCIDENTAL_SELECTION_CLEAR_WINDOW_MS);
  requestAnimationFrame(clearIfAny);
}

function onPointerDown(event) {
  tapArbiter.pointerDown({
    pointerId: event.pointerId,
    pointerType: event.pointerType,
    isPrimary: event.isPrimary,
    x: event.clientX,
    y: event.clientY,
  });
  onPointerEvent("down", event);
}

function onPointerUp(event) {
  tapArbiter.pointerUp({
    pointerId: event.pointerId,
    x: event.clientX,
    y: event.clientY,
  });
  onPointerEvent("up", event);
}

function onPointerMove(event) {
  tapArbiter.pointerMoved({
    pointerId: event.pointerId,
    x: event.clientX,
    y: event.clientY,
  });
  onPointerEvent("move", event);
}

function onPointerCancel(event) {
  tapArbiter.pointerCancelled({ pointerId: event.pointerId });
  onPointerEvent("cancel", event);
}

function onPointerEvent(phase, event) {
  // If the user is currently selecting text, we report this event as cancelled to prevent detecting gestures.
  if (isSelecting) {
    phase = "cancel";
  }

  // Looking for the elements is costly, so we avoid doing it on every move event.
  // Skipping interactiveElement for move events is intentional: the Swift-side filter
  // that ignores events on interactive elements is meant to prevent hijacking taps on
  // links and inputs, not drag/scroll gestures, so move events can safely bypass it.
  var interactiveElement;
  var targetElement;
  if (phase != "move") {
    interactiveElement = findNearestInteractiveElement(event.target);
    targetElement = extractTargetElement(event.target);
  }

  let point = adjustPointToViewport({ x: event.clientX, y: event.clientY });
  let pointerEvent = {
    phase: phase,
    defaultPrevented: event.defaultPrevented,
    pointerId: event.pointerId,
    pointerType: event.pointerType,
    x: point.x,
    y: point.y,
    buttons: event.buttons,
    interactiveElement: interactiveElement,
    targetElement: targetElement,
    option: event.altKey,
    control: event.ctrlKey,
    shift: event.shiftKey,
    command: event.metaKey,
  };

  if (findDecorationTarget(event) != null) {
    return;
  }

  // Send the pointer data over the JS bridge even if it's been handled
  // within the webview, so that it can be preserved and used
  // by the WKNavigationDelegate if needed.
  webkit.messageHandlers.pointerEventReceived.postMessage(pointerEvent);

  // We don't want to disable the default WebView behavior as it breaks some features without bringing any value.
  // event.stopPropagation();
  // event.preventDefault();
}

// Continuous scrolling happens in the top wrapper document
// (`index-continuous-wrapper.js`), not in this chapter iframe, so a purely
// iframe-local scroll listener would never see it. Same-origin same-window
// nesting lets us observe the wrapper's own `scroll` events directly via
// `window.parent`. Falls back to this window when there's no wrapping
// parent (e.g. a reflowable resource loaded at the top level).
function outerScrollTarget() {
  try {
    return window.parent && window.parent !== window ? window.parent : window;
  } catch (e) {
    return window;
  }
}

function observeOuterScrollForCancellation() {
  try {
    outerScrollTarget().addEventListener("scroll", onOuterScroll, {
      passive: true,
    });
  } catch (e) {
    // Cross-origin or otherwise inaccessible parent: block activation simply
    // won't be cancelled by outer scroll in that case. Arbitration still
    // degrades safely via its own movement/pointercancel checks.
  }
}

function onOuterScroll() {
  tapArbiter.outerScrolled();
}

/**
 * Extracts metadata about the target element for gesture handling.
 *
 * Returns an object with the element's bounding rectangle, tag name, source
 * URL, a CSS selector, the href of the document that contains the element,
 * an accessibility label, and a caption. This information is used on the
 * Swift side to build the appropriate `ContentElement`.
 */
function extractTargetElement(element) {
  if (!element || !element.getBoundingClientRect) {
    return null;
  }

  let imageElement = findNearestImageElement(element);
  if (!imageElement) {
    return null;
  }

  let rect = imageElement.getBoundingClientRect();
  // Adjust only the origin through the viewport transform; size is already
  // in viewport-relative units and does not depend on the frame offset.
  let adjustedOrigin = adjustPointToViewport({ x: rect.left, y: rect.top });

  let rawSrc =
    imageElement.getAttribute("src") ||
    imageElement.getAttribute("href") ||
    null;

  // Resolve the raw src/href attribute to an absolute URL using the document's
  // base URI. `getAttribute` returns the literal attribute value (possibly
  // relative), while we need the absolute form so Swift can relativize it
  // against the publication base URL to recover the correct manifest href.
  let src = rawSrc ? new URL(rawSrc, document.baseURI).href : null;

  // `html` is only needed for inline SVGs that have no resolvable `src`.
  let html = src ? null : imageElement.outerHTML;

  return {
    tag: imageElement.tagName.toLowerCase(),
    html: html,
    src: src,
    resourceHref: window.readium?.link?.href ?? null,
    frame: {
      x: adjustedOrigin.x,
      y: adjustedOrigin.y,
      width: rect.width,
      height: rect.height,
    },
    accessibilityLabel: imageElement.getAttribute("aria-label")?.trim() || null,
    caption: extractCaption(imageElement),
    cssSelector: getCssSelector(imageElement),
  };
}

/**
 * Returns a human-readable caption for an image element by checking, in
 * order: the `alt` attribute, the `title` attribute, the text content of the
 * first SVG `<title>` child, the text content of the first SVG `<desc>`
 * child, and the text content of a `<figcaption>` inside a parent `<figure>`.
 * Returns `null` when none of these are present.
 *
 * When `alt` is present — even as an empty string (decorative image) — no
 * other source is consulted, so that an explicit `alt=""` suppresses fallback
 * captions rather than incorrectly propagating them.
 */
function extractCaption(imageElement) {
  if (imageElement.hasAttribute("alt")) {
    const alt = imageElement.getAttribute("alt").trim();
    return alt || null;
  }

  const title = imageElement.getAttribute("title")?.trim();
  if (title) return title;

  const svgTitle = imageElement
    .querySelector(":scope > title")
    ?.textContent.trim();
  if (svgTitle) return svgTitle;

  const svgDesc = imageElement
    .querySelector(":scope > desc")
    ?.textContent.trim();
  if (svgDesc) return svgDesc;

  const figure = imageElement.closest("figure");
  if (figure) {
    const figcaption = figure.querySelector("figcaption")?.textContent.trim();
    if (figcaption) return figcaption;
  }

  return null;
}

/**
 * Walks up the DOM tree from the given element to find the nearest image
 * element (img, svg).
 */
function findNearestImageElement(element) {
  const imageTags = ["img", "svg"];
  let current = element;
  while (current && current !== document.documentElement) {
    if (imageTags.includes(current.tagName.toLowerCase())) {
      return current;
    }
    current = current.parentElement;
  }
  return null;
}
