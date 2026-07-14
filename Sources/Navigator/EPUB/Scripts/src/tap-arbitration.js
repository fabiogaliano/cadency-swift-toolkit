//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// Double-tap block-activation arbitration, extracted from the DOM listeners
// in `gestures.js` so the whole tap/double-tap/scroll/selection race lives in
// one deliberately DOM-free state machine. Inputs are plain data describing
// pointer, click, and scroll events; effects happen only through the injected
// `sendTap`/`isSelectionCollapsed`/timer dependencies, so tests can drive
// every timing sequence deterministically through the same interface the
// listeners use.
//
// Semantic blocks are opaque tokens here: the arbiter only ever compares them
// by identity (`===`), never inspects them, so callers can pass DOM elements
// without this module depending on the DOM.

// Kept generous enough for a real touch double-tap, tight enough to stay out
// of the way of two unrelated single taps.
export const DOUBLE_TAP_DELAY_MS = 250;
export const TAP_MOVEMENT_THRESHOLD_PX = 10;
export const DOUBLE_TAP_DISTANCE_THRESHOLD_PX = 40;
// Mirrors the continuous wrapper's own scroll-end debounce
// (`index-continuous-wrapper.js`'s `userScrollEndTimer`), so our
// "is the outer wrapper scrolling" signal settles on roughly the same
// cadence as the wrapper's own idea of "user scrolling".
export const WRAPPER_SCROLL_SETTLE_MS = 150;

export function createTapArbiter({
  sendTap,
  isSelectionCollapsed,
  now = () => Date.now(),
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = (id) => clearTimeout(id),
}) {
  // The pointer currently down, tracked only to compute per-tap movement and
  // pointer type/primary-ness for arbitration - never used to gate the
  // pre-existing, unconditional pointer-event forwarding in `gestures.js`.
  let activePointer = null;

  // The most recently completed low-movement pointer gesture (a candidate
  // "tap"), consumed by the very next `click`. Cleared to null whenever the
  // completing pointer moved past the tap threshold, so a click following a
  // drag never qualifies for arbitration.
  let lastCompletedTap = null;

  // A single-tap event delayed to see whether it pairs with a second tap on
  // the same semantic block - so the first tap of a double-tap never fires as
  // a plain tap (the native recognizer owns the resulting activation). Never
  // more than one at a time: a non-pairing second tap immediately resolves
  // this one as a plain tap first.
  let pendingSingleTap = null;

  let isWrapperScrolling = false;
  let wrapperScrollEndTimer = null;
  let suppressClicksUntil = 0;

  // Only the primary pointer is tracked for arbitration, so an incidental
  // secondary touch (e.g. a stray second finger) can never clobber tracking
  // of an in-flight primary-pointer tap.
  function pointerDown({ pointerId, pointerType, isPrimary, x, y }) {
    if (!isPrimary) {
      return;
    }
    activePointer = {
      pointerId,
      pointerType,
      isPrimary,
      startX: x,
      startY: y,
      moved: false,
    };
  }

  function pointerMoved({ pointerId, x, y }) {
    if (
      !activePointer ||
      pointerId !== activePointer.pointerId ||
      activePointer.moved
    ) {
      return;
    }
    const dx = x - activePointer.startX;
    const dy = y - activePointer.startY;
    if (Math.hypot(dx, dy) > TAP_MOVEMENT_THRESHOLD_PX) {
      activePointer.moved = true;
      // Movement beyond the tap threshold mid-gesture - likely the start of
      // a pan/scroll rather than a second tap. Drop any pending arbitration
      // immediately rather than waiting for a (possibly debounced) outer
      // scroll event to catch up.
      discardPendingTap();
    }
  }

  function pointerUp({ pointerId, x, y }) {
    if (activePointer && pointerId === activePointer.pointerId) {
      lastCompletedTap = activePointer.moved
        ? null
        : {
            pointerType: activePointer.pointerType,
            isPrimary: activePointer.isPrimary,
            x,
            y,
          };
      activePointer = null;
    } else {
      lastCompletedTap = null;
    }
  }

  function pointerCancelled({ pointerId }) {
    if (activePointer && pointerId === activePointer.pointerId) {
      activePointer = null;
    }
    lastCompletedTap = null;
    discardPendingTap();
  }

  function outerScrolled() {
    isWrapperScrolling = true;
    // A delayed single tap must never fire because of a scroll that started
    // after the tap was recorded.
    discardPendingTap();
    clearTimer(wrapperScrollEndTimer);
    wrapperScrollEndTimer = setTimer(() => {
      isWrapperScrolling = false;
    }, WRAPPER_SCROLL_SETTLE_MS);
  }

  function shouldSuppressClick() {
    return now() < suppressClicksUntil;
  }

  function hasPendingTap() {
    return pendingSingleTap != null;
  }

  // The native, public-API double-tap recognizer is about to activate a block
  // at this position: any pending first tap belongs to that double-tap, and
  // the synthetic clicks WebKit may still deliver for it must not reach
  // arbitration.
  function nativeActivationRequested() {
    discardPendingTap();
    suppressClicksUntil = now() + DOUBLE_TAP_DELAY_MS;
  }

  // A click that arrived while the selection was collapsed. `resolveBlock` is
  // a thunk so block resolution stays lazy: it only runs for taps that
  // actually qualify for arbitration, exactly as before extraction.
  //
  // Returns:
  //  - "forwarded": non-qualifying tap, already sent to native (in order,
  //    after any flushed pending tap). Callers leave the click's default alone.
  //  - "queued": a qualifying first tap now waiting out the double-tap window.
  //  - "swallowed-pair": the second tap of a double-tap; the pair is consumed
  //    and native owns the activation.
  // For both qualifying outcomes the caller should mark the click handled
  // (preventDefault) - plain touch/Pencil text clicks have no useful browser
  // default, and marking each candidate handled keeps WebKit from
  // interpreting a later paired tap as an unhandled smart-magnification
  // gesture. Links, controls, selections and mouse clicks never qualify.
  function tap({ clickEvent, resolveBlock }) {
    if (!isQualifyingTapCandidate(clickEvent)) {
      // Interactive content, a non-primary/secondary pointer, movement beyond
      // the tap threshold, or a mid-scroll tap. Flush any pending arbitration
      // first so native always receives taps in chronological order, then
      // forward this one immediately, exactly as before double-tap
      // arbitration existed.
      flushPendingTap();
      sendTap(clickEvent);
      return "forwarded";
    }

    const candidate = {
      clickEvent,
      block: resolveBlock(),
      pointerType: lastCompletedTap.pointerType,
      isPrimary: lastCompletedTap.isPrimary,
      x: lastCompletedTap.x,
      y: lastCompletedTap.y,
    };

    if (
      pendingSingleTap &&
      isQualifyingSecondTap(pendingSingleTap, candidate)
    ) {
      // Second tap of a double-tap. The native recognizer owns activation - on
      // device WebKit withholds this click once the recognizer wins, so this
      // branch only runs on platforms that still deliver it. Swallow the pair
      // so a double-tap never toggles reader controls.
      discardPendingTap();
      return "swallowed-pair";
    }

    // Not a pair for whatever was pending (different block, wrong pointer
    // type, too far apart, or nothing was pending): that earlier tap is
    // definitely a plain single tap now, so resolve it immediately instead of
    // waiting out its own timer.
    flushPendingTap();

    candidate.timer = setTimer(() => {
      pendingSingleTap = null;
      // A selection can start forming (e.g. a long press) without ever
      // producing a qualifying second tap to pair with. Rather than
      // discarding eagerly on `selectionchange` - which would also discard
      // the accidental word-selection a genuine second tap can trigger
      // before pairing gets a chance to run in `tapDuringSelection` - the
      // selection is checked once here, right before the tap would otherwise
      // fire. Non-collapsed means no pairing claimed this window, so the tap
      // is stale and dropped instead of firing mid-selection.
      if (isSelectionCollapsed()) {
        sendTap(candidate.clickEvent);
      }
    }, DOUBLE_TAP_DELAY_MS);
    pendingSingleTap = candidate;
    return "queued";
  }

  // WebKit can resolve a word selection as a side effect of the raw touch
  // that becomes the second tap of a double-tap - independent of, and
  // sometimes before, our own click-based arbitration ever sees that tap's
  // `click`. Without this, the selection guard in `gestures.js` would discard
  // the still-pending first tap and both taps would silently vanish: no
  // `tap`, no `blockActivated`. A pending tap can only exist here because the
  // first tap's own click already passed that same guard with a collapsed
  // selection, so its mere presence already proves this selection appeared
  // *during* the arbitration window, not before it - a genuine pre-existing
  // or long-press selection never reaches this function with a pairable
  // pending tap around.
  //
  // Returns "paired" when this click is the second tap of a double-tap (the
  // pair is consumed; the caller should mark the click handled to keep
  // WebKit's unhandled-double-tap smart-magnification fallback away, and the
  // accidental selection is deliberately left in place - the native
  // activation clears it only once `blockActivated` has actually been
  // posted). Returns "unclaimed" otherwise (wrong block, too far, wrong
  // pointer): the caller falls back to the original behavior - discard and
  // don't forward, so real selections still block activation.
  function tapDuringSelection({ clickEvent, resolveBlock }) {
    if (!pendingSingleTap || !isQualifyingTapCandidate(clickEvent)) {
      return "unclaimed";
    }

    const candidate = {
      block: resolveBlock(),
      pointerType: lastCompletedTap.pointerType,
      isPrimary: lastCompletedTap.isPrimary,
      x: lastCompletedTap.x,
      y: lastCompletedTap.y,
    };

    if (!isQualifyingSecondTap(pendingSingleTap, candidate)) {
      return "unclaimed";
    }

    discardPendingTap();
    return "paired";
  }

  // A tap only enters arbitration when it's unambiguously "plain": the
  // completing pointer barely moved, was the primary pointer, the target
  // isn't interactive content (decoration targets are already filtered out by
  // the caller), and the outer wrapper isn't mid-scroll.
  function isQualifyingTapCandidate(clickEvent) {
    return (
      !isWrapperScrolling &&
      clickEvent.interactiveElement == null &&
      lastCompletedTap != null &&
      lastCompletedTap.isPrimary &&
      isBlockActivationPointerType(lastCompletedTap.pointerType)
    );
  }

  function isBlockActivationPointerType(pointerType) {
    return pointerType === "touch" || pointerType === "pen";
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

  function discardPendingTap() {
    if (!pendingSingleTap) {
      return;
    }
    clearTimer(pendingSingleTap.timer);
    pendingSingleTap = null;
  }

  function flushPendingTap() {
    if (!pendingSingleTap) {
      return;
    }
    clearTimer(pendingSingleTap.timer);
    const tap = pendingSingleTap;
    pendingSingleTap = null;
    sendTap(tap.clickEvent);
  }

  // Timers must not survive iframe unload; the adapter calls this from
  // `pagehide`/`unload`.
  function dispose() {
    discardPendingTap();
    clearTimer(wrapperScrollEndTimer);
    activePointer = null;
    lastCompletedTap = null;
  }

  return {
    pointerDown,
    pointerMoved,
    pointerUp,
    pointerCancelled,
    outerScrolled,
    shouldSuppressClick,
    hasPendingTap,
    nativeActivationRequested,
    tap,
    tapDuringSelection,
    flushPendingTap,
    dispose,
  };
}
