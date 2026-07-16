import { describe, expect, it } from "vitest";
import { chapterProgression, mostVisibleChapter } from "../src/visible-locator";

// Viewport-relative rect helper: `top` is the chapter top's distance from
// the viewport top (negative once scrolled past it).
function rect(top, height) {
  return { top, height, bottom: top + height };
}

describe("chapterProgression", () => {
  it("is 0 while the chapter top is at or below the viewport top", () => {
    expect(chapterProgression(rect(0, 1000))).toBe(0);
    expect(chapterProgression(rect(300, 1000))).toBe(0);
  });

  it("is the scrolled fraction once the chapter top passes the viewport top", () => {
    expect(chapterProgression(rect(-250, 1000))).toBe(0.25);
    expect(chapterProgression(rect(-990, 1000))).toBe(0.99);
  });

  it("clamps to 1 when the chapter has fully scrolled past", () => {
    expect(chapterProgression(rect(-1500, 1000))).toBe(1);
  });

  it("is 0 for degenerate rects", () => {
    expect(chapterProgression(rect(-100, 0))).toBe(0);
    expect(chapterProgression(rect(-100, NaN))).toBe(0);
    expect(chapterProgression(null)).toBe(0);
    expect(chapterProgression(undefined)).toBe(0);
  });
});

describe("mostVisibleChapter", () => {
  const viewportHeight = 800;

  it("returns null with no chapters", () => {
    expect(mostVisibleChapter([], viewportHeight)).toBeNull();
  });

  it("returns null when every chapter is offscreen", () => {
    const chapters = [
      { spineIndex: 0, rect: rect(-2000, 1000) },
      { spineIndex: 2, rect: rect(900, 1000) },
    ];
    expect(mostVisibleChapter(chapters, viewportHeight)).toBeNull();
  });

  it("picks the chapter covering the most viewport height", () => {
    const chapters = [
      // Tail end: 300px still visible at the top of the viewport.
      { spineIndex: 3, rect: rect(-700, 1000) },
      // Fills the remaining 500px of the viewport.
      { spineIndex: 4, rect: rect(300, 1000) },
    ];
    expect(mostVisibleChapter(chapters, viewportHeight).spineIndex).toBe(4);
  });

  it("counts only the visible portion, not the chapter height", () => {
    const chapters = [
      // Huge chapter, but only 100px peeks into the viewport.
      { spineIndex: 0, rect: rect(700, 10000) },
      // Small chapter fully visible: 400px.
      { spineIndex: 1, rect: rect(100, 400) },
    ];
    expect(mostVisibleChapter(chapters, viewportHeight).spineIndex).toBe(1);
  });

  it("keeps the first of two equally visible chapters", () => {
    const chapters = [
      { spineIndex: 1, rect: rect(0, 400) },
      { spineIndex: 2, rect: rect(400, 400) },
    ];
    expect(mostVisibleChapter(chapters, viewportHeight).spineIndex).toBe(1);
  });
});
