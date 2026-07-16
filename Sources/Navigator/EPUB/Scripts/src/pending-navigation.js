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
     * replaces any pending target.
     * @returns {boolean} - Whether the navigation was accepted
     */
    navigate(spineIndex, locator) {
      pending = null;
      const state = getChapterState(spineIndex);
      log(`[goto-trace] goToStart index=${spineIndex} state=${state}`);
      const target = {
        spineIndex,
        locator,
        startedAt: now(),
        remountsLeft: MAX_ERROR_REMOUNTS,
      };

      if (state === "loaded") {
        return resolve(target);
      }

      pending = target;
      if (state !== "loading") {
        mountChapter(spineIndex);
      }
      // Immediate feedback: jump to the chapter's estimated start while the
      // iframe loads; resolution corrects to the precise locator.
      scrollToChapterStart(spineIndex);
      return true;
    },

    /** Hook for the chapter iframe's load event. */
    chapterLoaded(spineIndex) {
      if (pending?.spineIndex !== spineIndex) return;
      resolve(pending);
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
