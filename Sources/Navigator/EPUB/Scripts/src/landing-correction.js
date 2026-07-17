//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

/**
 * Re-resolves a navigation target while chapter geometry settles.
 *
 * The caller owns user-input detection and must call cancel() before direct
 * input can race another corrective scroll.
 */
export function createLandingCorrection({
  resolveTarget,
  getScrollY,
  scrollTo,
  requestFrame,
  cancelFrame,
  shouldCancel = () => false,
  onExhausted,
  maxFrames = 90,
  tolerance = 1,
}) {
  let active = null;

  function isActive() {
    return active != null;
  }

  /** Spine index still being corrected toward, or null when idle. */
  function targetIndex() {
    return active?.spineIndex ?? null;
  }

  function cancel() {
    if (active == null) return;
    cancelFrame(active.frameId);
    active = null;
  }

  function start(spineIndex, locator) {
    cancel();
    const state = { framesLeft: maxFrames, frameId: 0, spineIndex };
    active = state;

    const check = () => {
      if (active !== state) return;
      if (shouldCancel()) {
        active = null;
        return;
      }
      state.framesLeft -= 1;

      // Null means "not resolvable yet" — e.g. the target iframe's load event
      // fired before it was registered. Keep trying within the frame budget;
      // aborting here left cold restores stranded at the coarse spacer scroll.
      const target = resolveTarget(spineIndex, locator);
      let drift = null;
      if (target != null) {
        drift = Math.abs(getScrollY() - target);
        if (drift > tolerance) scrollTo(target);
      }

      if (state.framesLeft <= 0) {
        // -1: the budget ran out without the target ever resolving.
        if (drift == null || drift > tolerance) onExhausted(drift ?? -1);
        active = null;
        return;
      }
      state.frameId = requestFrame(check);
    };

    state.frameId = requestFrame(check);
  }

  return { cancel, isActive, start, targetIndex };
}
