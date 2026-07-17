//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// Geometry for the continuous wrapper's reading-position locators. Pure
// functions over viewport-relative chapter rects so the per-settle path
// stays testable without a DOM.

/**
 * Fraction of the chapter scrolled above the viewport top, clamped to [0, 1].
 * This is the chapter-level `progression` of the current reading position:
 * 0 while the chapter top is still on or below the viewport top, 1 once the
 * chapter has fully scrolled past.
 * @param {{top: number, height: number}} rect - Viewport-relative chapter rect
 * @returns {number}
 */
export function chapterProgression(rect) {
  if (!rect || !(rect.height > 0)) return 0;
  return Math.max(0, Math.min(1, -rect.top / rect.height));
}

/**
 * The on-screen slice of a chapter, in chapter-local coordinates. The
 * chapter's iframe is as tall as its content, so its own viewport can't
 * express "what the reader sees" — this translates the outer viewport
 * into the iframe's coordinate space instead.
 * @param {{top: number, height: number}} rect - Viewport-relative chapter rect
 * @param {number} viewportHeight
 * @returns {{top: number, bottom: number}}
 */
export function visibleWindowInChapter(rect, viewportHeight) {
  const top = Math.max(0, -rect.top);
  const bottom = Math.min(rect.height, viewportHeight - rect.top);
  return { top, bottom: Math.max(top, bottom) };
}

/**
 * Pick the first chapter visible from the viewport top downward. Exact
 * persistence anchors what the reader has reached, even when the next chapter
 * occupies more of the screen below a chapter boundary.
 * @param {Array<{rect: {top: number, bottom: number}}>} chapters
 * @param {number} viewportHeight
 * @returns {Object|null} - The topmost visible entry, or null
 */
export function chapterAtViewportTop(chapters, viewportHeight) {
  let best = null;
  let bestVisibleTop = viewportHeight;

  for (const chapter of chapters) {
    const visibleTop = Math.max(0, chapter.rect.top);
    const visibleBottom = Math.min(viewportHeight, chapter.rect.bottom);
    if (visibleBottom <= visibleTop) continue;

    if (visibleTop < bestVisibleTop) {
      bestVisibleTop = visibleTop;
      best = chapter;
    }
  }

  return best;
}

/**
 * Pick the chapter occupying the most viewport height.
 * @param {Array<{rect: {top: number, bottom: number}}>} chapters
 * @param {number} viewportHeight
 * @returns {Object|null} - The winning entry, or null when nothing is visible
 */
export function mostVisibleChapter(chapters, viewportHeight) {
  let best = null;
  let bestVisibility = 0;

  for (const chapter of chapters) {
    const visibleTop = Math.max(0, chapter.rect.top);
    const visibleBottom = Math.min(viewportHeight, chapter.rect.bottom);
    const visibleHeight = Math.max(0, visibleBottom - visibleTop);

    if (visibleHeight > bestVisibility) {
      bestVisibility = visibleHeight;
      best = chapter;
    }
  }

  return best;
}
