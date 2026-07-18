import { describe, expect, it } from "vite-plus/test";
import {
  createPendingNavigation,
  MAX_ERROR_REMOUNTS,
} from "../src/pending-navigation";

const LOCATOR = { href: "chapter3.xhtml", locations: { progression: 0.5 } };

// Fake chapter lifecycle: mounting flips a chapter to "loading"; the test
// drives load/error events explicitly, the way the wrapper's iframe
// listeners would.
function createHarness(initialStates = {}) {
  const states = new Map(
    Object.entries(initialStates).map(([k, v]) => [Number(k), v])
  );
  const mounts = [];
  const scrolls = [];
  const startJumps = [];
  const logs = [];
  let nowMs = 0;

  const nav = createPendingNavigation({
    getChapterState: (spineIndex) => states.get(spineIndex),
    mountChapter: (spineIndex) => {
      mounts.push(spineIndex);
      states.set(spineIndex, "loading");
    },
    scrollToTarget: (spineIndex, locator) => {
      scrolls.push({ spineIndex, locator });
      return true;
    },
    scrollToChapterStart: (spineIndex) => startJumps.push(spineIndex),
    log: (message) => logs.push(message),
    now: () => nowMs,
  });

  function loadChapter(spineIndex) {
    states.set(spineIndex, "loaded");
    nav.chapterLoaded(spineIndex);
  }

  function failChapter(spineIndex) {
    states.set(spineIndex, "error");
    nav.chapterFailed(spineIndex);
  }

  return {
    nav,
    states,
    mounts,
    scrolls,
    startJumps,
    logs,
    loadChapter,
    failChapter,
    advance: (ms) => (nowMs += ms),
  };
}

describe("navigate", () => {
  it("scrolls immediately when the chapter is already loaded", async () => {
    const h = createHarness({ 3: "loaded" });
    await expect(h.nav.navigate(3, LOCATOR)).resolves.toBe(true);
    expect(h.scrolls).toEqual([{ spineIndex: 3, locator: LOCATOR }]);
    expect(h.mounts).toEqual([]);
    expect(h.startJumps).toEqual([]);
    expect(h.nav.isTarget(3)).toBe(false);
  });

  it("mounts an unmounted chapter, jumps to its start, and scrolls precisely once it loads", async () => {
    const h = createHarness({ 3: "spacer" });
    const completion = h.nav.navigate(3, LOCATOR);
    expect(h.mounts).toEqual([3]);
    expect(h.startJumps).toEqual([3]);
    expect(h.scrolls).toEqual([]);

    h.loadChapter(3);
    expect(h.scrolls).toEqual([{ spineIndex: 3, locator: LOCATOR }]);
    expect(h.nav.isTarget(3)).toBe(false);
    await expect(completion).resolves.toBe(true);
  });

  it("does not settle the completion before the chapter loads", async () => {
    const h = createHarness({ 3: "spacer" });
    let settled = false;
    const completion = h.nav.navigate(3, LOCATOR).then((scrolled) => {
      settled = true;
      return scrolled;
    });
    await Promise.resolve();
    expect(settled).toBe(false);

    h.loadChapter(3);
    await expect(completion).resolves.toBe(true);
  });

  it("does not remount a chapter that is already loading", async () => {
    const h = createHarness({ 3: "loading" });
    const completion = h.nav.navigate(3, LOCATOR);
    expect(h.mounts).toEqual([]);

    h.loadChapter(3);
    expect(h.scrolls).toEqual([{ spineIndex: 3, locator: LOCATOR }]);
    await expect(completion).resolves.toBe(true);
  });

  it("replaces a pending target when a new navigation arrives, settling it false", async () => {
    const h = createHarness({ 3: "spacer", 7: "spacer" });
    const superseded = h.nav.navigate(3, LOCATOR);
    const otherLocator = { href: "chapter7.xhtml" };
    const completion = h.nav.navigate(7, otherLocator);
    expect(h.nav.isTarget(3)).toBe(false);
    expect(h.nav.isTarget(7)).toBe(true);
    await expect(superseded).resolves.toBe(false);

    h.loadChapter(3);
    expect(h.scrolls).toEqual([]);

    h.loadChapter(7);
    expect(h.scrolls).toEqual([{ spineIndex: 7, locator: otherLocator }]);
    await expect(completion).resolves.toBe(true);
  });
});

describe("load and error events", () => {
  it("ignores loads of chapters that are not the pending target", () => {
    const h = createHarness({ 3: "spacer" });
    h.nav.navigate(3, LOCATOR);
    h.loadChapter(5);
    expect(h.scrolls).toEqual([]);
    expect(h.nav.isTarget(3)).toBe(true);
  });

  it("ignores events when nothing is pending", () => {
    const h = createHarness();
    h.loadChapter(3);
    h.failChapter(3);
    expect(h.scrolls).toEqual([]);
    expect(h.mounts).toEqual([]);
  });

  it("remounts a failing chapter a bounded number of times, then gives up settling false", async () => {
    const h = createHarness({ 3: "error" });
    const completion = h.nav.navigate(3, LOCATOR);
    expect(h.mounts).toEqual([3]);

    for (let i = 0; i < MAX_ERROR_REMOUNTS; i++) {
      h.failChapter(3);
    }
    expect(h.mounts).toEqual([3, 3, 3]);
    expect(h.nav.isTarget(3)).toBe(true);

    h.failChapter(3);
    expect(h.mounts).toEqual([3, 3, 3]);
    expect(h.nav.isTarget(3)).toBe(false);
    expect(h.logs.some((m) => m.includes("goToFailed index=3"))).toBe(true);
    expect(h.scrolls).toEqual([]);
    await expect(completion).resolves.toBe(false);
  });

  it("scrolls when a chapter loads after an error remount", async () => {
    const h = createHarness({ 3: "error" });
    const completion = h.nav.navigate(3, LOCATOR);
    h.failChapter(3);
    h.loadChapter(3);
    expect(h.scrolls).toEqual([{ spineIndex: 3, locator: LOCATOR }]);
    await expect(completion).resolves.toBe(true);
  });
});

describe("goto-trace marks", () => {
  it("reports elapsed time and remount count on resolution", () => {
    const h = createHarness({ 3: "error" });
    h.nav.navigate(3, LOCATOR);
    h.failChapter(3);
    h.advance(150);
    h.loadChapter(3);

    expect(h.logs).toContain("[goto-trace] goToStart index=3 state=error");
    expect(h.logs).toContain(
      "[goto-trace] goToScrolled index=3 dt=150ms remounts=1"
    );
  });
});
