import { describe, expect, it } from "vite-plus/test";

import { shouldPostPointerEvent } from "../../../src/cadency/interaction/pointer-bridge";

describe("continuous pointer bridge", () => {
  it("keeps pointer movement inside a continuous chapter", () => {
    expect(shouldPostPointerEvent("move", true)).toBe(false);
  });

  it.each(["down", "up", "cancel"] as const)(
    "keeps %s messages required by native input observers",
    (phase) => {
      expect(shouldPostPointerEvent(phase, true)).toBe(true);
    }
  );

  it("preserves stock navigator move messages", () => {
    expect(shouldPostPointerEvent("move", false)).toBe(true);
  });
});
