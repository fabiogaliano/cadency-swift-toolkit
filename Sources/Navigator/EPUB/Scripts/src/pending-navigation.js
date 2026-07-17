//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// Event-driven goTo resolution for the continuous wrapper. Holds a single
// pending navigation target and scrolls when the chapter's iframe load event
// fires, instead of polling on a timer. Chapters in error state get a bounded
// remount budget so a persistently failing chapter cannot remount forever.

export const MAX_ERROR_REMOUNTS = 2;

export function createPendingNavigation({
  getChapterState,
  mountChapter,
  scrollToTarget,
  scrollToChapterStart = () => {},
  log,
  now = Date.now,
}) {
  let pending = null;

  function resolve(target) {
    pending = null;
    const scrolled = scrollToTarget(target.spineIndex, target.locator);
    log(
      `[goto-trace] goToScrolled index=${target.spineIndex} dt=${
        now() - target.startedAt
      }ms remounts=${MAX_ERROR_REMOUNTS - target.remountsLeft}`
    );
    return scrolled;
  }

  return {
    /**
     * Navigate to a locator in a chapter: scroll immediately when loaded,
     * otherwise once the chapter's iframe load event fires. A new call
     * replaces any pending target, settling its promise false.
     * @returns {Promise<boolean>} - Settles when the navigation's scroll ran
     *   (or definitively won't): true once the precise scroll happened, false
     *   when the target chapter failed for good or the navigation was
     *   superseded. The native side awaits this for truthful completion.
     */
    navigate(spineIndex, locator) {
      if (pending) {
        log(`[goto-trace] goToSuperseded index=${pending.spineIndex}`);
        pending.settle(false);
        pending = null;
      }
      const state = getChapterState(spineIndex);
      log(`[goto-trace] goToStart index=${spineIndex} state=${state}`);
      const target = {
        spineIndex,
        locator,
        startedAt: now(),
        remountsLeft: MAX_ERROR_REMOUNTS,
        settle: () => {},
      };

      if (state === "loaded") {
        return Promise.resolve(resolve(target));
      }

      const completion = new Promise((settle) => {
        target.settle = settle;
      });
      pending = target;
      if (state !== "loading") {
        mountChapter(spineIndex);
      }
      // Immediate feedback: jump to the chapter's estimated start while the
      // iframe loads; resolution corrects to the precise locator.
      scrollToChapterStart(spineIndex);
      return completion;
    },

    /** Hook for the chapter iframe's load event. */
    chapterLoaded(spineIndex) {
      if (pending?.spineIndex !== spineIndex) return;
      const target = pending;
      target.settle(resolve(target));
    },

    /** Hook for the chapter iframe's error event. */
    chapterFailed(spineIndex) {
      if (pending?.spineIndex !== spineIndex) return;
      if (pending.remountsLeft > 0) {
        pending.remountsLeft -= 1;
        mountChapter(spineIndex);
        return;
      }
      log(
        `[goto-trace] goToFailed index=${spineIndex} remounts=${MAX_ERROR_REMOUNTS}`
      );
      pending.settle(false);
      pending = null;
    },

    /**
     * Whether a pending navigation targets this chapter. The sliding mount
     * window must not unmount the target while its load is awaited, or the
     * navigation would never resolve.
     */
    isTarget(spineIndex) {
      return pending?.spineIndex === spineIndex;
    },
  };
}
