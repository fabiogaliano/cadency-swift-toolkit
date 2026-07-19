import { describe, expect, it } from "vite-plus/test";

import { progressionPayload } from "../../../src/cadency/continuous/progression";

describe("progressionPayload", () => {
  it("calculates the first and last visible progression", () => {
    expect(
      progressionPayload({
        totalHeight: 1_000,
        viewportHeight: 200,
        scrollY: 400,
        activeChapterIndex: 3,
      })
    ).toEqual({ first: 0.5, last: 0.6, activeChapter: 3 });
  });

  it("clamps empty, short, and overscrolled documents", () => {
    expect(
      progressionPayload({
        totalHeight: 0,
        viewportHeight: 0,
        scrollY: 0,
        activeChapterIndex: 0,
      })
    ).toEqual({ first: 0, last: 0, activeChapter: 0 });
    expect(
      progressionPayload({
        totalHeight: 100,
        viewportHeight: 200,
        scrollY: -20,
        activeChapterIndex: 0,
      })
    ).toEqual({ first: 0, last: 1, activeChapter: 0 });
    expect(
      progressionPayload({
        totalHeight: 100,
        viewportHeight: 200,
        scrollY: 500,
        activeChapterIndex: 1,
      })
    ).toEqual({ first: 1, last: 1, activeChapter: 1 });
  });
});
