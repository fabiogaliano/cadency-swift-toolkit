import { describe, expect, it } from "vite-plus/test";
import {
  createTapArbiter,
  DOUBLE_TAP_DELAY_MS,
  DOUBLE_TAP_DISTANCE_THRESHOLD_PX,
  TAP_MOVEMENT_THRESHOLD_PX,
  WRAPPER_SCROLL_SETTLE_MS,
  type TapArbiterClickEvent,
} from "../../../src/cadency/interaction/tap-arbitration";

// Semantic blocks are opaque identity tokens to the arbiter.
const BLOCK_A = { name: "block-a" };
const BLOCK_B = { name: "block-b" };

interface TestClickEvent extends TapArbiterClickEvent {
  x: number;
  y: number;
}

// Deterministic clock + timer queue so every arbitration race can be driven
// through the same interface the DOM adapter uses.
function createHarness() {
  let nowMs = 0;
  let nextTimerId = 1;
  const timers = new Map<number, { fireAt: number; fn: () => void }>();
  const sentTaps: TapArbiterClickEvent[] = [];
  const selection = { collapsed: true };

  const arbiter = createTapArbiter({
    sendTap: (clickEvent) => sentTaps.push(clickEvent),
    isSelectionCollapsed: () => selection.collapsed,
    now: () => nowMs,
    setTimer: (fn, ms) => {
      const id = nextTimerId++;
      timers.set(id, { fireAt: nowMs + ms, fn });
      return id;
    },
    clearTimer: (id) => {
      if (id != null) {
        timers.delete(id);
      }
    },
  });

  function advance(ms: number) {
    const target = nowMs + ms;
    for (;;) {
      let dueId: number | null = null;
      let due: { fireAt: number; fn: () => void } | null = null;
      for (const [id, timer] of timers) {
        if (timer.fireAt <= target && (!due || timer.fireAt < due.fireAt)) {
          dueId = id;
          due = timer;
        }
      }
      if (!due || dueId == null) break;
      timers.delete(dueId);
      nowMs = due.fireAt;
      due.fn();
    }
    nowMs = target;
  }

  return { arbiter, advance, sentTaps, selection, timers };
}

type Harness = ReturnType<typeof createHarness>;

// A complete down/up gesture followed by its click, the way the DOM adapter
// delivers them.
function performTap(
  harness: Harness,
  {
    block = BLOCK_A,
    x = 100,
    y = 100,
    pointerType = "touch",
    isPrimary = true,
    pointerId = 1,
    interactiveElement = null,
  }: {
    block?: unknown;
    x?: number;
    y?: number;
    pointerType?: string;
    isPrimary?: boolean;
    pointerId?: number;
    interactiveElement?: unknown;
  } = {}
) {
  harness.arbiter.pointerDown({ pointerId, pointerType, isPrimary, x, y });
  harness.arbiter.pointerUp({ pointerId, x, y });
  const clickEvent: TestClickEvent = { x, y, interactiveElement };
  const outcome = harness.arbiter.tap({
    clickEvent,
    resolveBlock: () => block,
  });
  return { outcome, clickEvent };
}

describe("single tap", () => {
  it("queues a qualifying tap and fires it only after the double-tap delay", () => {
    const h = createHarness();
    const { outcome, clickEvent } = performTap(h);
    expect(outcome).toBe("queued");

    h.advance(DOUBLE_TAP_DELAY_MS - 1);
    expect(h.sentTaps).toEqual([]);

    h.advance(1);
    expect(h.sentTaps).toEqual([clickEvent]);
  });

  it("drops a queued tap if a selection exists when its timer fires", () => {
    const h = createHarness();
    performTap(h);
    h.selection.collapsed = false;
    h.advance(DOUBLE_TAP_DELAY_MS);
    expect(h.sentTaps).toEqual([]);
  });
});

describe("double tap", () => {
  it("swallows a pair on the same block within the distance threshold", () => {
    const h = createHarness();
    performTap(h, { x: 100, y: 100 });
    h.advance(50);
    const second = performTap(h, { x: 110, y: 105 });
    expect(second.outcome).toBe("swallowed-pair");

    h.advance(DOUBLE_TAP_DELAY_MS * 2);
    expect(h.sentTaps).toEqual([]);
  });

  it("treats taps on different blocks as two singles, flushing the first in order", () => {
    const h = createHarness();
    const first = performTap(h, { block: BLOCK_A });
    h.advance(50);
    const second = performTap(h, { block: BLOCK_B });
    expect(second.outcome).toBe("queued");
    // The first tap resolves immediately when the second fails to pair.
    expect(h.sentTaps).toEqual([first.clickEvent]);

    h.advance(DOUBLE_TAP_DELAY_MS);
    expect(h.sentTaps).toEqual([first.clickEvent, second.clickEvent]);
  });

  it("does not pair taps farther apart than the distance threshold", () => {
    const h = createHarness();
    const first = performTap(h, { x: 100, y: 100 });
    h.advance(50);
    const second = performTap(h, {
      x: 100 + DOUBLE_TAP_DISTANCE_THRESHOLD_PX + 1,
      y: 100,
    });
    expect(second.outcome).toBe("queued");
    expect(h.sentTaps).toEqual([first.clickEvent]);
  });

  it("does not pair taps with different pointer types", () => {
    const h = createHarness();
    performTap(h, { pointerType: "touch" });
    h.advance(50);
    const second = performTap(h, { pointerType: "pen" });
    expect(second.outcome).toBe("queued");
    expect(h.sentTaps).toHaveLength(1);
  });

  it("never pairs when a block could not be resolved for either tap", () => {
    const h = createHarness();
    performTap(h, { block: null });
    h.advance(50);
    const second = performTap(h, { block: null });
    expect(second.outcome).toBe("queued");
    expect(h.sentTaps).toHaveLength(1);
  });
});

describe("qualification", () => {
  it("forwards mouse clicks immediately", () => {
    const h = createHarness();
    const { outcome, clickEvent } = performTap(h, { pointerType: "mouse" });
    expect(outcome).toBe("forwarded");
    expect(h.sentTaps).toEqual([clickEvent]);
  });

  it("lets pen taps enter arbitration", () => {
    const h = createHarness();
    expect(performTap(h, { pointerType: "pen" }).outcome).toBe("queued");
  });

  it("forwards taps on interactive content immediately, flushing the pending tap first", () => {
    const h = createHarness();
    const first = performTap(h);
    const second = performTap(h, { interactiveElement: "a" });
    expect(second.outcome).toBe("forwarded");
    expect(h.sentTaps).toEqual([first.clickEvent, second.clickEvent]);
  });

  it("forwards clicks whose completing pointer moved past the tap threshold", () => {
    const h = createHarness();
    h.arbiter.pointerDown({
      pointerId: 1,
      pointerType: "touch",
      isPrimary: true,
      x: 100,
      y: 100,
    });
    h.arbiter.pointerMoved({
      pointerId: 1,
      x: 100 + TAP_MOVEMENT_THRESHOLD_PX + 1,
      y: 100,
    });
    h.arbiter.pointerUp({ pointerId: 1, x: 120, y: 100 });
    const clickEvent: TestClickEvent = {
      x: 120,
      y: 100,
      interactiveElement: null,
    };
    const outcome = h.arbiter.tap({
      clickEvent,
      resolveBlock: () => BLOCK_A,
    });
    expect(outcome).toBe("forwarded");
  });

  it("never lets a non-primary pointer qualify", () => {
    const h = createHarness();
    const { outcome } = performTap(h, { isPrimary: false });
    expect(outcome).toBe("forwarded");
  });
});

describe("scroll cancellation", () => {
  it("discards a pending tap when the outer wrapper scrolls", () => {
    const h = createHarness();
    performTap(h);
    h.arbiter.outerScrolled();
    h.advance(DOUBLE_TAP_DELAY_MS * 2);
    expect(h.sentTaps).toEqual([]);
  });

  it("forwards taps immediately while the wrapper is scrolling", () => {
    const h = createHarness();
    h.arbiter.outerScrolled();
    expect(performTap(h).outcome).toBe("forwarded");
  });

  it("lets taps qualify again once scrolling settles", () => {
    const h = createHarness();
    h.arbiter.outerScrolled();
    h.advance(WRAPPER_SCROLL_SETTLE_MS);
    expect(performTap(h).outcome).toBe("queued");
  });

  it("discards a pending tap when the primary pointer starts panning", () => {
    const h = createHarness();
    performTap(h);
    h.arbiter.pointerDown({
      pointerId: 2,
      pointerType: "touch",
      isPrimary: true,
      x: 100,
      y: 100,
    });
    h.arbiter.pointerMoved({
      pointerId: 2,
      x: 100,
      y: 100 + TAP_MOVEMENT_THRESHOLD_PX + 1,
    });
    h.advance(DOUBLE_TAP_DELAY_MS * 2);
    expect(h.sentTaps).toEqual([]);
  });

  it("discards a pending tap on pointer cancellation", () => {
    const h = createHarness();
    performTap(h);
    h.arbiter.pointerCancelled({ pointerId: 1 });
    h.advance(DOUBLE_TAP_DELAY_MS * 2);
    expect(h.sentTaps).toEqual([]);
  });
});

describe("accidental selection pairing", () => {
  // WebKit can select a word as a side effect of the second tap's raw touch,
  // before its click reaches arbitration. The pair must still be recognized.
  function tapWithSelection(
    h: Harness,
    {
      block = BLOCK_A,
      x = 105,
      y = 100,
    }: { block?: unknown; x?: number; y?: number } = {}
  ) {
    h.arbiter.pointerDown({
      pointerId: 2,
      pointerType: "touch",
      isPrimary: true,
      x,
      y,
    });
    h.arbiter.pointerUp({ pointerId: 2, x, y });
    const clickEvent: TestClickEvent = { x, y, interactiveElement: null };
    return h.arbiter.tapDuringSelection({
      clickEvent,
      resolveBlock: () => block,
    });
  }

  it("pairs a second tap whose raw touch spawned a selection, consuming both", () => {
    const h = createHarness();
    performTap(h);
    h.advance(50);
    h.selection.collapsed = false;

    expect(tapWithSelection(h)).toBe("paired");
    expect(h.arbiter.hasPendingTap()).toBe(false);
    h.advance(DOUBLE_TAP_DELAY_MS * 2);
    expect(h.sentTaps).toEqual([]);
  });

  it("leaves a non-pairing tap unclaimed so the caller can flush the pending tap", () => {
    const h = createHarness();
    const first = performTap(h, { block: BLOCK_A });
    h.advance(50);
    h.selection.collapsed = false;

    expect(tapWithSelection(h, { block: BLOCK_B })).toBe("unclaimed");
    expect(h.arbiter.hasPendingTap()).toBe(true);

    h.arbiter.flushPendingTap();
    expect(h.sentTaps).toEqual([first.clickEvent]);
  });

  it("is unclaimed when nothing is pending", () => {
    const h = createHarness();
    h.selection.collapsed = false;
    expect(tapWithSelection(h)).toBe("unclaimed");
  });
});

describe("native activation", () => {
  it("discards the pending first tap and suppresses trailing clicks", () => {
    const h = createHarness();
    performTap(h);
    h.arbiter.nativeActivationRequested();

    expect(h.arbiter.hasPendingTap()).toBe(false);
    expect(h.arbiter.shouldSuppressClick()).toBe(true);

    h.advance(DOUBLE_TAP_DELAY_MS);
    expect(h.arbiter.shouldSuppressClick()).toBe(false);
    expect(h.sentTaps).toEqual([]);
  });
});

describe("teardown", () => {
  it("cancels all timers so nothing fires after the iframe unloads", () => {
    const h = createHarness();
    performTap(h);
    h.arbiter.outerScrolled();
    h.arbiter.dispose();

    expect(h.timers.size).toBe(0);
    h.advance(DOUBLE_TAP_DELAY_MS * 2);
    expect(h.sentTaps).toEqual([]);
  });
});
