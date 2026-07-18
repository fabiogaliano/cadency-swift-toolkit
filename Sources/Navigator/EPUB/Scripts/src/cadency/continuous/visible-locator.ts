//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// Geometry for the continuous wrapper's reading-position locators. Pure
// functions over viewport-relative chapter rects so the per-settle path
// stays testable without a DOM.

/** Viewport-relative chapter rect, as read from `getBoundingClientRect()`. */
interface ChapterRect {
  top: number;
  height: number;
}

/** The viewport-relative span of a chapter used for visibility comparisons. */
interface ViewportSpan {
  top: number;
  bottom: number;
}

/** A chapter entry carrying at least its viewport span; callers attach more
 * (spine index, iframe, ...) which these functions pass through untouched. */
interface ChapterWithSpan {
  rect: ViewportSpan;
}

/**
 * Fraction of the chapter scrolled above the viewport top, clamped to [0, 1].
 * This is the chapter-level `progression` of the current reading position:
 * 0 while the chapter top is still on or below the viewport top, 1 once the
 * chapter has fully scrolled past.
 */
export function chapterProgression(
  rect: ChapterRect | null | undefined
): number {
  if (!rect || !(rect.height > 0)) return 0;
  return Math.max(0, Math.min(1, -rect.top / rect.height));
}

/**
 * The on-screen slice of a chapter, in chapter-local coordinates. The
 * chapter's iframe is as tall as its content, so its own viewport can't
 * express "what the reader sees" — this translates the outer viewport
 * into the iframe's coordinate space instead.
 */
export function visibleWindowInChapter(
  rect: ChapterRect,
  viewportHeight: number
): ViewportSpan {
  const top = Math.max(0, -rect.top);
  const bottom = Math.min(rect.height, viewportHeight - rect.top);
  return { top, bottom: Math.max(top, bottom) };
}

/**
 * Pick the first chapter visible from the viewport top downward. Exact
 * persistence anchors what the reader has reached, even when the next chapter
 * occupies more of the screen below a chapter boundary.
 */
export function chapterAtViewportTop<T extends ChapterWithSpan>(
  chapters: readonly T[],
  viewportHeight: number
): T | null {
  let best: T | null = null;
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
 */
export function mostVisibleChapter<T extends ChapterWithSpan>(
  chapters: readonly T[],
  viewportHeight: number
): T | null {
  let best: T | null = null;
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
