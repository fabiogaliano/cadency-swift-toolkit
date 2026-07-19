import { describe, expect, it } from "vite-plus/test";

import {
  cancelLandingCorrectionScroll,
  classifyScroll,
  createScrollSession,
  extendAnchorSuppression,
  extendLandingCorrectionScroll,
  extendProgrammaticScroll,
  isAnchoringSuppressed,
  isProgrammaticScrollActive,
} from "../../../src/cadency/continuous/scroll-session";

describe("scroll-session", () => {
  it("extends suppression and programmatic deadlines without shortening them", () => {
    let state = createScrollSession(0, 0);
    state = extendAnchorSuppression(state, 100, 750);
    state = extendAnchorSuppression(state, 200, 100);
    state = extendProgrammaticScroll(state, 100, 250);
    state = extendProgrammaticScroll(state, 200, 50);
    state = extendLandingCorrectionScroll(state, 100, 250);
    state = extendLandingCorrectionScroll(state, 200, 25);

    expect(isAnchoringSuppressed(state, 849)).toBe(true);
    expect(isAnchoringSuppressed(state, 850)).toBe(false);
    expect(isProgrammaticScrollActive(state, 349)).toBe(true);
    expect(isProgrammaticScrollActive(state, 350)).toBe(false);
  });

  it("cancels landing-correction and programmatic deadlines together", () => {
    const state = cancelLandingCorrectionScroll(
      extendLandingCorrectionScroll(
        extendProgrammaticScroll(createScrollSession(0, 0), 100, 250),
        100,
        250
      )
    );

    expect(isProgrammaticScrollActive(state, 101)).toBe(false);
  });

  it("classifies viewport-sized and high-velocity jumps", () => {
    const state = createScrollSession(0, 100);

    expect(
      classifyScroll(state, {
        now: 200,
        scrollY: 801,
        viewportHeight: 800,
        userScrolling: false,
      }).kind
    ).toBe("begin-user-scroll");
    expect(
      classifyScroll(state, {
        now: 110,
        scrollY: 201,
        viewportHeight: 800,
        userScrolling: false,
      }).kind
    ).toBe("begin-user-scroll");
  });

  it("does not classify quarter-viewport movement at velocity 10", () => {
    expect(
      classifyScroll(createScrollSession(0, 100), {
        now: 120,
        scrollY: 200,
        viewportHeight: 800,
        userScrolling: false,
      }).kind
    ).toBe("none");
  });

  it("throttles large-jump center recomputation for 120 ms", () => {
    const begun = classifyScroll(createScrollSession(0, 0), {
      now: 100,
      scrollY: 1_601,
      viewportHeight: 800,
      userScrolling: false,
    });
    const throttled = classifyScroll(begun.state, {
      now: 220,
      scrollY: 3_202,
      viewportHeight: 800,
      userScrolling: true,
    });
    const recompute = classifyScroll(throttled.state, {
      now: 221,
      scrollY: 4_803,
      viewportHeight: 800,
      userScrolling: true,
    });

    expect(throttled.kind).toBe("none");
    expect(recompute.kind).toBe("recompute-center");
  });

  it("records scroll observations while programmatic scrolling is active", () => {
    const active = extendProgrammaticScroll(
      createScrollSession(10, 100),
      100,
      250
    );
    const decision = classifyScroll(active, {
      now: 110,
      scrollY: 2_000,
      viewportHeight: 800,
      userScrolling: false,
    });

    expect(decision.kind).toBe("none");
    expect(decision.state.previousScrollY).toBe(2_000);
    expect(decision.state.previousScrollTime).toBe(110);
  });
});
