export interface ScrollSessionState {
  suppressAnchoringUntil: number;
  programmaticScrollUntil: number;
  landingCorrectionScrollUntil: number;
  previousScrollY: number;
  previousScrollTime: number;
  lastCenterComputationTime: number;
}

export type ScrollDecision =
  | { kind: "begin-user-scroll"; state: ScrollSessionState }
  | { kind: "recompute-center"; state: ScrollSessionState }
  | { kind: "none"; state: ScrollSessionState };

export function createScrollSession(
  scrollY: number,
  now: number
): ScrollSessionState {
  return {
    suppressAnchoringUntil: 0,
    programmaticScrollUntil: 0,
    landingCorrectionScrollUntil: 0,
    previousScrollY: scrollY,
    previousScrollTime: now,
    lastCenterComputationTime: 0,
  };
}

export function extendAnchorSuppression(
  state: ScrollSessionState,
  now: number,
  durationMs: number
): ScrollSessionState {
  return {
    ...state,
    suppressAnchoringUntil: Math.max(
      state.suppressAnchoringUntil,
      now + durationMs
    ),
  };
}

export function extendProgrammaticScroll(
  state: ScrollSessionState,
  now: number,
  durationMs: number
): ScrollSessionState {
  return {
    ...state,
    programmaticScrollUntil: Math.max(
      state.programmaticScrollUntil,
      now + durationMs
    ),
  };
}

export function extendLandingCorrectionScroll(
  state: ScrollSessionState,
  now: number,
  durationMs: number
): ScrollSessionState {
  return {
    ...state,
    landingCorrectionScrollUntil: Math.max(
      state.landingCorrectionScrollUntil,
      now + durationMs
    ),
  };
}

export function cancelLandingCorrectionScroll(
  state: ScrollSessionState
): ScrollSessionState {
  return {
    ...state,
    landingCorrectionScrollUntil: 0,
    programmaticScrollUntil: 0,
  };
}

export function isAnchoringSuppressed(
  state: ScrollSessionState,
  now: number
): boolean {
  return now < state.suppressAnchoringUntil;
}

export function isProgrammaticScrollActive(
  state: ScrollSessionState,
  now: number
): boolean {
  return (
    now < state.programmaticScrollUntil ||
    now < state.landingCorrectionScrollUntil
  );
}

export function hasLandingCorrectionScrollPending(
  state: ScrollSessionState,
  now: number
): boolean {
  return now < state.landingCorrectionScrollUntil;
}

export function classifyScroll(
  state: ScrollSessionState,
  input: {
    now: number;
    scrollY: number;
    viewportHeight: number;
    userScrolling: boolean;
  }
): ScrollDecision {
  const deltaY = Math.abs(input.scrollY - state.previousScrollY);
  const deltaTime = input.now - state.previousScrollTime;
  const observedState = {
    ...state,
    previousScrollY: input.scrollY,
    previousScrollTime: input.now,
  };

  if (isProgrammaticScrollActive(state, input.now)) {
    return { kind: "none", state: observedState };
  }

  const velocity = deltaTime > 0 ? deltaY / deltaTime : 0;
  const isJumpLike =
    deltaY > input.viewportHeight ||
    (velocity > 10 && deltaY > input.viewportHeight * 0.25);
  if (!isJumpLike) {
    return { kind: "none", state: observedState };
  }

  if (!input.userScrolling) {
    return {
      kind: "begin-user-scroll",
      state: { ...observedState, lastCenterComputationTime: input.now },
    };
  }

  const isLargeJump = deltaY > input.viewportHeight * 2;
  if (isLargeJump && input.now - state.lastCenterComputationTime > 120) {
    return {
      kind: "recompute-center",
      state: { ...observedState, lastCenterComputationTime: input.now },
    };
  }

  return { kind: "none", state: observedState };
}
