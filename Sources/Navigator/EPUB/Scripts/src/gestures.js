//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import { findDecorationTarget, handleDecorationClickEvent } from "./decorator";
import { adjustPointToViewport, toTopViewportRect } from "./rect";
import { findNearestInteractiveElement } from "./dom";
import {
  resolveSemanticBlockForTarget,
  buildBlockActivationPayload,
} from "./blocks";
import { logError } from "./utils";

let isSelecting = false;

// Double-tap block-activation arbitration tuning. Kept generous enough for a
// real touch double-tap, tight enough to stay out of the way of two
// unrelated single taps.
const DOUBLE_TAP_DELAY_MS = 250;
const TAP_MOVEMENT_THRESHOLD_PX = 10;
const DOUBLE_TAP_DISTANCE_THRESHOLD_PX = 40;
// Mirrors the continuous wrapper's own scroll-end debounce
// (`index-continuous-wrapper.js`'s `userScrollEndTimer`), so our
// "is the outer wrapper scrolling" signal settles on roughly the same
// cadence as the wrapper's own idea of "user scrolling".
const WRAPPER_SCROLL_SETTLE_MS = 150;

// The pointer currently down, tracked only to compute per-tap movement and
// pointer type/primary-ness for arbitration - never used to gate the
// pre-existing, unconditional pointer-event forwarding below.
let activePointer = null;

// The most recently completed low-movement pointer gesture (a candidate
// "tap"), consumed by the very next `click`. Cleared to null whenever the
// completing pointer moved past the tap threshold, so a click following a
// drag never qualifies for arbitration.
let lastCompletedTap = null;

// A single-tap event delayed to see whether it pairs with a second tap on
// the same semantic block. Never more than one at a time: a non-pairing
// second tap immediately resolves this one as a plain tap first.
let pendingSingleTap = null;

let isWrapperScrolling = false;
let wrapperScrollEndTimer = null;

window.addEventListener("DOMContentLoaded", function () {
  document.addEventListener("click", onClick, false);
  document.addEventListener("pointerdown", onPointerDown, false);
  document.addEventListener("pointerup", onPointerUp, false);
  document.addEventListener("pointermove", onPointerMove, false);
  document.addEventListener("pointercancel", onPointerCancel, false);

  document.addEventListener("selectionchange", function () {
    isSelecting = !window.getSelection().isCollapsed;
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
  discardPendingSingleTap();
  clearTimeout(wrapperScrollEndTimer);
  try {
    outerScrollTarget().removeEventListener("scroll", onOuterScroll);
  } catch (e) {
    // Parent already gone/inaccessible - nothing left to detach.
  }
  activePointer = null;
  lastCompletedTap = null;
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
    if (tryPairAccidentalSelectionTap(event)) {
      return;
    }
    // A genuine pre-existing (or long-press) selection: the tap will
    // dismiss it, so we don't forward it. Any pending arbitration belongs
    // to an earlier legitimate tap that simply failed to pair with this
    // one, so flush it (emitting its tap once, in order) instead of
    // silently swallowing it.
    flushPendingSingleTap();
    return;
  }

  const clickEvent = buildClickEvent(event);

  if (handleDecorationClickEvent(event, clickEvent)) {
    return;
  }

  if (!isQualifyingTapCandidate(clickEvent)) {
    // Interactive content, a non-primary/secondary pointer, movement beyond
    // the tap threshold, or a mid-scroll tap. Flush any pending arbitration
    // first so native always receives taps in chronological order, then
    // forward this one immediately, exactly as before double-tap
    // arbitration existed.
    flushPendingSingleTap();
    sendTap(clickEvent);
    return;
  }

  handleQualifyingTap(event, clickEvent);

  // We don't want to disable the default WebView behavior as it breaks some features without bringing any value.
  // event.stopPropagation();
  // event.preventDefault();
}

// WebKit can resolve a word selection as a side effect of the raw touch that
// becomes the second tap of a double-tap - independent of, and sometimes
// before, our own click-based arbitration ever sees that tap's `click`.
// Without this, the selection guard in `onClick` above would discard the
// still-pending first tap and both taps would silently vanish: no `tap`,
// no `blockActivated`. `pendingSingleTap` can only exist here because the
// first tap's own click already passed that same guard with a collapsed
// selection, so its mere presence already proves this selection appeared
// *during* the arbitration window, not before it - a genuine pre-existing or
// long-press selection never reaches this function with a pairable
// `pendingSingleTap` around. If this tap doesn't actually pair (wrong block,
// too far, wrong pointer), the caller falls back to the original behavior:
// discard and don't forward, so real selections still block activation.
function tryPairAccidentalSelectionTap(event) {
  if (!pendingSingleTap) {
    return false;
  }

  const clickEvent = buildClickEvent(event);
  if (handleDecorationClickEvent(event, clickEvent)) {
    return true;
  }
  if (!isQualifyingTapCandidate(clickEvent)) {
    return false;
  }

  const tap = {
    block: resolveSemanticBlockForTarget(event.target),
    pointerType: lastCompletedTap.pointerType,
    isPrimary: lastCompletedTap.isPrimary,
    x: lastCompletedTap.x,
    y: lastCompletedTap.y,
  };

  if (!isQualifyingSecondTap(pendingSingleTap, tap)) {
    return false;
  }

  clearTimeout(pendingSingleTap.timer);
  const pending = pendingSingleTap;
  pendingSingleTap = null;
  if (!activateBlock(pending.block)) {
    // Same fallback as the ordinary pairing path: a failed activation emits
    // the pending first tap exactly once rather than dropping both taps. The
    // accidental selection is deliberately left in place - only a successful
    // activation clears it.
    sendTap(pending.clickEvent);
  }
  return true;
}

function handleQualifyingTap(event, clickEvent) {
  const block = resolveSemanticBlockForTarget(event.target);
  const tap = {
    clickEvent,
    block,
    pointerType: lastCompletedTap.pointerType,
    isPrimary: lastCompletedTap.isPrimary,
    x: lastCompletedTap.x,
    y: lastCompletedTap.y,
  };

  if (pendingSingleTap && isQualifyingSecondTap(pendingSingleTap, tap)) {
    clearTimeout(pendingSingleTap.timer);
    const pending = pendingSingleTap;
    pendingSingleTap = null;
    if (!activateBlock(pending.block)) {
      // A qualifying double tap whose activation failed (no Locator/payload,
      // an unusable rect, or a postMessage error) must not swallow both taps:
      // fall back to emitting the first tap's normal tap exactly once.
      sendTap(pending.clickEvent);
    }
    return;
  }

  // Not a pair for whatever was pending (different block, wrong pointer
  // type, too far apart, or nothing was pending): that earlier tap is
  // definitely a plain single tap now, so resolve it immediately instead of
  // waiting out its own timer.
  flushPendingSingleTap();

  pendingSingleTap = {
    clickEvent: tap.clickEvent,
    block: tap.block,
    pointerType: tap.pointerType,
    isPrimary: tap.isPrimary,
    x: tap.x,
    y: tap.y,
    timer: setTimeout(() => {
      pendingSingleTap = null;
      // A selection can start forming (e.g. a long press) without ever
      // producing a qualifying second tap to pair with. Rather than
      // discarding eagerly on `selectionchange` - which would also discard
      // the accidental word-selection a genuine second tap can trigger
      // before pairing gets a chance to run in `tryPairAccidentalSelectionTap`
      // above - the selection is checked once here, right before the tap
      // would otherwise fire. Non-collapsed means no pairing claimed this
      // window, so the tap is stale and dropped instead of firing mid-selection.
      if (getSelection().isCollapsed) {
        sendTap(tap.clickEvent);
      }
    }, DOUBLE_TAP_DELAY_MS),
  };
}

// A tap only enters arbitration when it's unambiguously "plain": the
// completing pointer barely moved, was the primary pointer, the target isn't
// interactive content (decoration targets are already filtered out above),
// and the outer wrapper isn't mid-scroll.
function isQualifyingTapCandidate(clickEvent) {
  return (
    !isWrapperScrolling &&
    clickEvent.interactiveElement == null &&
    lastCompletedTap != null &&
    lastCompletedTap.isPrimary
  );
}

function isQualifyingSecondTap(pending, tap) {
  return (
    pending.block != null &&
    tap.block != null &&
    pending.block === tap.block &&
    pending.pointerType === tap.pointerType &&
    pending.isPrimary &&
    tap.isPrimary &&
    Math.hypot(tap.x - pending.x, tap.y - pending.y) <=
      DOUBLE_TAP_DISTANCE_THRESHOLD_PX
  );
}

function discardPendingSingleTap() {
  if (!pendingSingleTap) {
    return;
  }
  clearTimeout(pendingSingleTap.timer);
  pendingSingleTap = null;
}

function flushPendingSingleTap() {
  if (!pendingSingleTap) {
    return;
  }
  clearTimeout(pendingSingleTap.timer);
  const tap = pendingSingleTap;
  pendingSingleTap = null;
  sendTap(tap.clickEvent);
}

function sendTap(clickEvent) {
  // Send the tap data over the JS bridge even if it's been handled
  // within the webview, so that it can be preserved and used
  // by the WKNavigationDelegate if needed.
  webkit.messageHandlers.tap.postMessage(clickEvent);
}

// Attempts to report a block activation to native. Returns true only once the
// `blockActivated` message has actually been posted; returns false on any
// failure (no Locator/payload, an unusable rect, or a postMessage error) so the
// caller can fall back to emitting the pending single tap instead of losing it.
function activateBlock(blockElement) {
  try {
    const payload = buildBlockActivationPayload(blockElement);
    if (!payload) {
      return false;
    }

    const rect = toTopViewportRect(payload.iframeRect);
    if (!isFiniteNativeRect(rect)) {
      // Pre-check so a coordinate-conversion edge case never reaches Swift,
      // which strictly drops rects that aren't finite/positive anyway.
      return false;
    }

    webkit.messageHandlers.blockActivated.postMessage({
      locator: payload.locator,
      rect,
      blockKey: payload.blockKey,
    });

    // Clear the accidental WebKit word selection only now that activation has
    // actually been reported - a failed activation leaves any selection intact.
    clearAccidentalWordSelection();
    return true;
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
// proactively, so long-press selection and its handles are untouched, and
// deferred a frame so it runs after any such WebKit side effect has landed.
function clearAccidentalWordSelection() {
  requestAnimationFrame(() => {
    const selection = window.getSelection();
    if (selection && !selection.isCollapsed) {
      selection.removeAllRanges();
    }
  });
}

function onPointerDown(event) {
  // Only the primary pointer is tracked for arbitration, so an incidental
  // secondary touch (e.g. a stray second finger) can never clobber tracking
  // of an in-flight primary-pointer tap.
  if (event.isPrimary) {
    activePointer = {
      pointerId: event.pointerId,
      pointerType: event.pointerType,
      isPrimary: event.isPrimary,
      startX: event.clientX,
      startY: event.clientY,
      moved: false,
    };
  }
  onPointerEvent("down", event);
}

function onPointerUp(event) {
  if (activePointer && event.pointerId === activePointer.pointerId) {
    lastCompletedTap = activePointer.moved
      ? null
      : {
          pointerType: activePointer.pointerType,
          isPrimary: activePointer.isPrimary,
          x: event.clientX,
          y: event.clientY,
        };
    activePointer = null;
  } else {
    lastCompletedTap = null;
  }
  onPointerEvent("up", event);
}

function onPointerMove(event) {
  if (
    activePointer &&
    event.pointerId === activePointer.pointerId &&
    !activePointer.moved
  ) {
    const dx = event.clientX - activePointer.startX;
    const dy = event.clientY - activePointer.startY;
    if (Math.hypot(dx, dy) > TAP_MOVEMENT_THRESHOLD_PX) {
      activePointer.moved = true;
      // Movement beyond the tap threshold mid-gesture - likely the start of
      // a pan/scroll rather than a second tap. Drop any pending arbitration
      // immediately rather than waiting for a (possibly debounced) outer
      // scroll event to catch up.
      discardPendingSingleTap();
    }
  }
  onPointerEvent("move", event);
}

function onPointerCancel(event) {
  if (activePointer && event.pointerId === activePointer.pointerId) {
    activePointer = null;
  }
  lastCompletedTap = null;
  discardPendingSingleTap();
  onPointerEvent("cancel", event);
}

function onPointerEvent(phase, event) {
  // If the user is currently selecting text, we report this event as cancelled to prevent detecting gestures.
  if (isSelecting) {
    phase = "cancel";
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
    targetElement: event.target.outerHTML,
    interactiveElement: findNearestInteractiveElement(event.target),
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
  isWrapperScrolling = true;
  // A delayed single tap must never fire because of a scroll that started
  // after the tap was recorded.
  discardPendingSingleTap();
  clearTimeout(wrapperScrollEndTimer);
  wrapperScrollEndTimer = setTimeout(() => {
    isWrapperScrolling = false;
  }, WRAPPER_SCROLL_SETTLE_MS);
}
