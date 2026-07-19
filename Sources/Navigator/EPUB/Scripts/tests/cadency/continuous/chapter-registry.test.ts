import { describe, expect, it } from "vite-plus/test";

import { ChapterRegistry } from "../../../src/cadency/continuous/chapter-registry";

interface TestIframe {
  id: string;
}

describe("ChapterRegistry", () => {
  it("applies every legal lifecycle transition", () => {
    const registry = new ChapterRegistry<TestIframe>();
    const iframe = { id: "chapter" };

    expect(registry.initialize(0, 800)).toEqual({ kind: "applied" });
    expect(registry.beginLoading(0, iframe)).toEqual({ kind: "applied" });
    expect(registry.loaded(0, iframe)).toEqual({ kind: "applied" });
    expect(registry.unmount(0, 900)).toEqual({ kind: "applied" });
    expect(registry.beginLoading(0, iframe)).toEqual({ kind: "applied" });
    expect(registry.failed(0, iframe)).toEqual({ kind: "applied" });
    expect(registry.unmount(0, 900)).toEqual({ kind: "applied" });
  });

  it("rejects illegal transitions explicitly", () => {
    const registry = new ChapterRegistry<TestIframe>();
    const iframe = { id: "chapter" };

    expect(registry.beginLoading(0, iframe)).toEqual({
      kind: "illegal",
      transition: "spacer -> loading",
      currentState: "absent",
    });
    registry.initialize(0, 800);
    expect(registry.initialize(0, 800).kind).toBe("illegal");
    registry.beginLoading(0, iframe);
    expect(registry.beginLoading(0, iframe).kind).toBe("illegal");
  });

  it("ignores stale load and error callbacks", () => {
    const registry = new ChapterRegistry<TestIframe>();
    const current = { id: "current" };
    const stale = { id: "stale" };
    registry.initialize(0, 800);
    registry.beginLoading(0, current);

    expect(registry.loaded(0, stale)).toEqual({ kind: "stale" });
    expect(registry.failed(0, stale)).toEqual({ kind: "stale" });
    registry.loaded(0, current);
    expect(registry.loaded(0, current)).toEqual({ kind: "stale" });
    expect(registry.failed(0, current)).toEqual({ kind: "stale" });
  });

  it("enumerates mounted chapters and exposes iframes only for iframe-bearing states", () => {
    const registry = new ChapterRegistry<TestIframe>();
    const loading = { id: "loading" };
    const loaded = { id: "loaded" };
    registry.initialize(0, 800);
    registry.initialize(1, 800);
    registry.initialize(2, 800);
    registry.beginLoading(1, loading);
    registry.beginLoading(2, loaded);
    registry.loaded(2, loaded);

    expect(registry.mountedIndices()).toEqual([1, 2]);
    expect(registry.iframe(0)).toBeUndefined();
    expect(registry.iframe(1)).toBe(loading);
    expect(registry.iframe(2)).toBe(loaded);
  });

  it("retains height across unmount and remount", () => {
    const registry = new ChapterRegistry<TestIframe>();
    const iframe = { id: "chapter" };
    registry.initialize(0, 800);
    registry.beginLoading(0, iframe);
    registry.updateHeight(0, 1_200);
    registry.unmount(0, 1_300);
    registry.beginLoading(0, iframe);

    expect(registry.height(0)).toBe(1_300);
  });

  it("cannot construct a loaded state without an iframe or expose one from a spacer", () => {
    const registry = new ChapterRegistry<TestIframe>();
    const iframe = { id: "chapter" };
    registry.initialize(0, 800);

    expect(registry.state(0)).toBe("spacer");
    expect(registry.iframe(0)).toBeUndefined();
    expect(registry.loaded(0, iframe)).toEqual({ kind: "stale" });
    expect(registry.state(0)).toBe("spacer");
  });
});
