import { describe, expect, it, vi } from "vitest";
import { createLandingCorrection } from "../src/landing-correction";

function frameHarness() {
  let nextId = 1;
  const frames = new Map();
  return {
    requestFrame(callback) {
      const id = nextId;
      nextId += 1;
      frames.set(id, callback);
      return id;
    },
    cancelFrame(id) {
      frames.delete(id);
    },
    runNext() {
      const next = frames.entries().next().value;
      if (!next) return false;
      const [id, callback] = next;
      frames.delete(id);
      callback();
      return true;
    },
    get pendingCount() {
      return frames.size;
    },
  };
}

function setup(overrides = {}) {
  const frames = frameHarness();
  const scrollTo = vi.fn();
  const onExhausted = vi.fn();
  const correction = createLandingCorrection({
    resolveTarget: () => 400,
    getScrollY: () => 0,
    scrollTo,
    requestFrame: (callback) => frames.requestFrame(callback),
    cancelFrame: (id) => frames.cancelFrame(id),
    onExhausted,
    ...overrides,
  });
  return { correction, frames, onExhausted, scrollTo };
}

describe("landing correction", () => {
  it("stops before another corrective scroll when user input cancels it", () => {
    const { correction, frames, scrollTo } = setup();

    correction.start(2, { href: "chapter.xhtml" });

    expect(correction.cancelFromUserInput()).toBe(true);
    expect(frames.pendingCount).toBe(0);
    expect(scrollTo).not.toHaveBeenCalled();
  });

  it("does not claim unrelated user input when no correction is active", () => {
    const { correction } = setup();

    expect(correction.cancelFromUserInput()).toBe(false);
  });

  it("stops when the wrapper detects a user scroll", () => {
    const { correction, frames, scrollTo } = setup({
      shouldCancel: () => true,
    });

    correction.start(2, { href: "chapter.xhtml" });
    frames.runNext();

    expect(scrollTo).not.toHaveBeenCalled();
    expect(frames.pendingCount).toBe(0);
  });

  it("re-resolves and corrects drift while geometry is settling", () => {
    let target = 400;
    const { correction, frames, scrollTo } = setup({
      resolveTarget: () => target,
    });

    correction.start(2, { href: "chapter.xhtml" });
    frames.runNext();
    target = 650;
    frames.runNext();

    expect(scrollTo).toHaveBeenNthCalledWith(1, 400);
    expect(scrollTo).toHaveBeenNthCalledWith(2, 650);
  });

  it("stops at the frame budget and reports remaining drift", () => {
    const { correction, frames, onExhausted, scrollTo } = setup({
      maxFrames: 2,
    });

    correction.start(2, { href: "chapter.xhtml" });
    while (frames.pendingCount > 0) {
      frames.runNext();
    }

    expect(scrollTo).toHaveBeenCalledTimes(2);
    expect(onExhausted).toHaveBeenCalledWith(400);
    expect(frames.pendingCount).toBe(0);
  });

  it("reports active from start until it stops, so scroll heuristics can defer to it", () => {
    let target = 400;
    const { correction, frames } = setup({
      getScrollY: () => 400,
      resolveTarget: () => target,
      maxFrames: 2,
    });

    expect(correction.isActive()).toBe(false);
    correction.start(2, { href: "chapter.xhtml" });
    expect(correction.isActive()).toBe(true);

    while (frames.pendingCount > 0) {
      frames.runNext();
    }
    expect(correction.isActive()).toBe(false);

    correction.start(2, { href: "chapter.xhtml" });
    correction.cancel();
    expect(correction.isActive()).toBe(false);
  });

  it("exposes the target spine index while active, so mount centering can pin to it", () => {
    const { correction, frames } = setup({ maxFrames: 1 });

    expect(correction.targetIndex()).toBe(null);
    correction.start(7, { href: "chapter.xhtml" });
    expect(correction.targetIndex()).toBe(7);

    while (frames.pendingCount > 0) {
      frames.runNext();
    }
    expect(correction.targetIndex()).toBe(null);
  });

  it("keeps retrying while the target is unresolvable and lands once it appears", () => {
    let target = null;
    const { correction, frames, scrollTo } = setup({
      resolveTarget: () => target,
    });

    correction.start(2, { href: "chapter.xhtml" });
    frames.runNext();
    frames.runNext();
    expect(scrollTo).not.toHaveBeenCalled();

    target = 400;
    frames.runNext();
    expect(scrollTo).toHaveBeenCalledWith(400);
  });

  it("stops cleanly when the target never resolves within the budget", () => {
    const { correction, frames, onExhausted, scrollTo } = setup({
      resolveTarget: () => null,
      maxFrames: 3,
    });

    correction.start(2, { href: "chapter.xhtml" });
    while (frames.pendingCount > 0) {
      frames.runNext();
    }

    expect(scrollTo).not.toHaveBeenCalled();
    expect(correction.isActive()).toBe(false);
    expect(onExhausted).toHaveBeenCalledWith(-1);
  });
});
