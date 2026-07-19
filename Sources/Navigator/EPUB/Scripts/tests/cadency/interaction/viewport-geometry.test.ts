import { describe, expect, it } from "vite-plus/test";

import { toTopViewportRect } from "../../../src/cadency/interaction/viewport-geometry";

describe("toTopViewportRect", () => {
  it("leaves an iframe-local rect unchanged without a frame offset", () => {
    const rect = { x: 0, y: 0, width: 320, height: 48 };

    expect(toTopViewportRect(rect, undefined)).toBe(rect);
  });

  it("adds positive frame offsets without changing width or height", () => {
    expect(
      toTopViewportRect(
        { x: 12, y: 34, width: 320, height: 48 },
        { x: 100, y: 200 }
      )
    ).toEqual({ x: 112, y: 234, width: 320, height: 48 });
  });

  it("preserves zero frame offsets", () => {
    expect(
      toTopViewportRect(
        { x: 12, y: 34, width: 320, height: 48 },
        { x: 0, y: 0 }
      )
    ).toEqual({ x: 12, y: 34, width: 320, height: 48 });
  });
});
