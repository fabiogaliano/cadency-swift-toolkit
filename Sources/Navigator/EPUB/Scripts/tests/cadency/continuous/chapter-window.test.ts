import { describe, expect, it } from "vite-plus/test";

import { planChapterWindow } from "../../../src/cadency/continuous/chapter-window";

const configuration = { prefetchBehind: 1, prefetchAhead: 2, maxMounted: 4 };

describe("planChapterWindow", () => {
  it("clamps ordinary mount windows at the first and last spine items", () => {
    expect(
      planChapterWindow({
        requestedCenterIndex: 0,
        landingCorrectionTarget: undefined,
        spineItemCount: 5,
        loadedChapterIndices: [],
        pendingNavigationTarget: undefined,
        userScrolling: false,
        configuration,
      }).indicesToMount
    ).toEqual([0, 1, 2]);
    expect(
      planChapterWindow({
        requestedCenterIndex: 4,
        landingCorrectionTarget: undefined,
        spineItemCount: 5,
        loadedChapterIndices: [],
        pendingNavigationTarget: undefined,
        userScrolling: false,
        configuration,
      }).indicesToMount
    ).toEqual([3, 4]);
  });

  it("uses the landing-correction target instead of a transient viewport center", () => {
    expect(
      planChapterWindow({
        requestedCenterIndex: 1,
        landingCorrectionTarget: 5,
        spineItemCount: 8,
        loadedChapterIndices: [],
        pendingNavigationTarget: undefined,
        userScrolling: false,
        configuration,
      }).indicesToMount
    ).toEqual([4, 5, 6, 7]);
  });

  it("does not evict a pending navigation target", () => {
    expect(
      planChapterWindow({
        requestedCenterIndex: 2,
        landingCorrectionTarget: undefined,
        spineItemCount: 10,
        loadedChapterIndices: [0, 1, 2, 3, 4, 5, 9],
        pendingNavigationTarget: 9,
        userScrolling: false,
        configuration,
      }).indicesToUnmount
    ).toEqual([5, 0]);
  });

  it("uses the expanded fast-scroll allowance before evicting furthest chapters", () => {
    const result = planChapterWindow({
      requestedCenterIndex: 5,
      landingCorrectionTarget: undefined,
      spineItemCount: 20,
      loadedChapterIndices: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
      pendingNavigationTarget: undefined,
      userScrolling: true,
      configuration,
    });

    expect(result.indicesToUnmount).toEqual([12, 11, 0, 10, 1]);
  });

  it("keeps out-of-window chapters mounted while the projected set is under the limit", () => {
    expect(
      planChapterWindow({
        requestedCenterIndex: 5,
        landingCorrectionTarget: undefined,
        spineItemCount: 10,
        loadedChapterIndices: [0, 4, 5],
        pendingNavigationTarget: undefined,
        userScrolling: false,
        configuration: {
          prefetchBehind: 0,
          prefetchAhead: 1,
          maxMounted: 4,
        },
      }).indicesToUnmount
    ).toEqual([]);
  });

  it("evicts for overflow introduced by the chapters it plans to mount", () => {
    expect(
      planChapterWindow({
        requestedCenterIndex: 5,
        landingCorrectionTarget: undefined,
        spineItemCount: 10,
        loadedChapterIndices: [0, 1, 2, 3],
        pendingNavigationTarget: undefined,
        userScrolling: false,
        configuration,
      })
    ).toEqual({
      indicesToMount: [4, 5, 6, 7],
      indicesToUnmount: [0, 1, 2, 3],
    });
  });

  it("keeps the requested prefetch window when max-mounted is smaller", () => {
    expect(
      planChapterWindow({
        requestedCenterIndex: 2,
        landingCorrectionTarget: undefined,
        spineItemCount: 5,
        loadedChapterIndices: [0, 1, 2, 3, 4],
        pendingNavigationTarget: undefined,
        userScrolling: false,
        configuration: {
          prefetchBehind: 2,
          prefetchAhead: 2,
          maxMounted: 2,
        },
      })
    ).toEqual({ indicesToMount: [0, 1, 2, 3, 4], indicesToUnmount: [] });
  });

  it("returns an empty plan for an empty spine", () => {
    expect(
      planChapterWindow({
        requestedCenterIndex: 0,
        landingCorrectionTarget: undefined,
        spineItemCount: 0,
        loadedChapterIndices: [0],
        pendingNavigationTarget: undefined,
        userScrolling: false,
        configuration: { ...configuration, maxMounted: 1 },
      })
    ).toEqual({ indicesToMount: [], indicesToUnmount: [] });
  });
});
