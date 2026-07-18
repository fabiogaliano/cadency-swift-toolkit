//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

export interface LandingCorrectionOptions {
  /** Re-resolves the scroll target; null means "not resolvable yet". */
  resolveTarget: (spineIndex: number, locator: unknown) => number | null;
  getScrollY: () => number;
  scrollTo: (target: number) => void;
  requestFrame: (callback: () => void) => number;
  cancelFrame: (frameId: number) => void;
  shouldCancel?: () => boolean;
  onExhausted: (drift: number) => void;
  maxFrames?: number;
  tolerance?: number;
}

interface LandingCorrection {
  cancel(): void;
  cancelFromUserInput(): boolean;
  isActive(): boolean;
  start(spineIndex: number, locator: unknown): void;
  /** Spine index still being corrected toward, or null when idle. */
  targetIndex(): number | null;
}

/** The in-flight correction's per-run bookkeeping; `active` is null when idle. */
interface ActiveCorrection {
  framesLeft: number;
  frameId: number;
  spineIndex: number;
}

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
}: LandingCorrectionOptions): LandingCorrection {
  let active: ActiveCorrection | null = null;

  function isActive(): boolean {
    return active != null;
  }

  /** Spine index still being corrected toward, or null when idle. */
  function targetIndex(): number | null {
    return active?.spineIndex ?? null;
  }

  function cancel(): void {
    if (active == null) return;
    cancelFrame(active.frameId);
    active = null;
  }

  function cancelFromUserInput(): boolean {
    if (active == null) return false;
    cancel();
    return true;
  }

  function start(spineIndex: number, locator: unknown): void {
    cancel();
    const state: ActiveCorrection = {
      framesLeft: maxFrames,
      frameId: 0,
      spineIndex,
    };
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
      let drift: number | null = null;
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

  return { cancel, cancelFromUserInput, isActive, start, targetIndex };
}
