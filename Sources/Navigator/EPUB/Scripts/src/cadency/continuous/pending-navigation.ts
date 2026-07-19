//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// Event-driven goTo resolution for the continuous wrapper. Holds a single
// pending navigation target and scrolls when the chapter's iframe load event
// fires, instead of polling on a timer. Chapters in error state get a bounded
// remount budget so a persistently failing chapter cannot remount forever.

/** Lifecycle states a chapter can report; matches index-continuous-wrapper.js. */
export type ChapterLifecycleState = "spacer" | "loading" | "loaded" | "error";

export interface PendingNavigationOptions {
  getChapterState: (spineIndex: number) => ChapterLifecycleState | undefined;
  mountChapter: (spineIndex: number) => void;
  scrollToTarget: (spineIndex: number, locator: unknown) => boolean;
  scrollToChapterStart?: (spineIndex: number) => void;
  log: (message: string) => void;
  now?: () => number;
}

/**
 * A single in-flight navigation. `settle` is always a real callback (never
 * optional) so a pending target without a way to settle its promise cannot
 * be represented.
 */
interface PendingTarget {
  spineIndex: number;
  locator: unknown;
  startedAt: number;
  remountsLeft: number;
  settle: (result: boolean) => void;
}

/** Idle vs pending is a closed union: a "pending" state always carries its target. */
type PendingNavigationState =
  | { status: "idle" }
  | { status: "pending"; target: PendingTarget };

interface PendingNavigation {
  /**
   * Navigate to a locator in a chapter: scroll immediately when loaded,
   * otherwise once the chapter's iframe load event fires. A new call
   * replaces the pending target, settling its promise false.
   * @returns Settles when the navigation's scroll ran (or definitively
   *   won't): true once the precise scroll happened, false when the target
   *   chapter failed for good or the navigation was superseded. The native
   *   side awaits this for truthful completion.
   */
  navigate(spineIndex: number, locator: unknown): Promise<boolean>;
  /** Hook for the chapter iframe's load event. */
  chapterLoaded(spineIndex: number): void;
  /** Hook for the chapter iframe's error event. */
  chapterFailed(spineIndex: number): void;
  /**
   * Whether a pending navigation targets this chapter. The sliding mount
   * window must not unmount the target while its load is awaited, or the
   * navigation would never resolve.
   */
  isTarget(spineIndex: number): boolean;
}

export const MAX_ERROR_REMOUNTS = 2;

export function createPendingNavigation({
  getChapterState,
  mountChapter,
  scrollToTarget,
  scrollToChapterStart = () => {},
  log,
  now = Date.now,
}: PendingNavigationOptions): PendingNavigation {
  let state: PendingNavigationState = { status: "idle" };

  function resolve(target: PendingTarget): boolean {
    state = { status: "idle" };
    const scrolled = scrollToTarget(target.spineIndex, target.locator);
    log(
      `[goto-trace] goToScrolled index=${target.spineIndex} dt=${
        now() - target.startedAt
      }ms remounts=${MAX_ERROR_REMOUNTS - target.remountsLeft}`
    );
    return scrolled;
  }

  return {
    navigate(spineIndex, locator) {
      if (state.status === "pending") {
        log(`[goto-trace] goToSuperseded index=${state.target.spineIndex}`);
        state.target.settle(false);
        state = { status: "idle" };
      }
      const chapterState = getChapterState(spineIndex);
      log(`[goto-trace] goToStart index=${spineIndex} state=${chapterState}`);
      const target: PendingTarget = {
        spineIndex,
        locator,
        startedAt: now(),
        remountsLeft: MAX_ERROR_REMOUNTS,
        settle: () => {},
      };

      if (chapterState === "loaded") {
        return Promise.resolve(resolve(target));
      }

      const completion = new Promise<boolean>((settle) => {
        target.settle = settle;
      });
      state = { status: "pending", target };
      if (chapterState !== "loading") {
        mountChapter(spineIndex);
      }
      // Immediate feedback: jump to the chapter's estimated start while the
      // iframe loads; resolution corrects to the precise locator.
      scrollToChapterStart(spineIndex);
      return completion;
    },

    chapterLoaded(spineIndex) {
      if (state.status !== "pending" || state.target.spineIndex !== spineIndex)
        return;
      const target = state.target;
      target.settle(resolve(target));
    },

    chapterFailed(spineIndex) {
      if (state.status !== "pending" || state.target.spineIndex !== spineIndex)
        return;
      if (state.target.remountsLeft > 0) {
        state.target.remountsLeft -= 1;
        mountChapter(spineIndex);
        return;
      }
      log(
        `[goto-trace] goToFailed index=${spineIndex} remounts=${MAX_ERROR_REMOUNTS}`
      );
      state.target.settle(false);
      state = { status: "idle" };
    },

    isTarget(spineIndex) {
      return (
        state.status === "pending" && state.target.spineIndex === spineIndex
      );
    },
  };
}
