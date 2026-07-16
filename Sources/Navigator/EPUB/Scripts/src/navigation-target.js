//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// Resolves a navigation target: which spine item a locator's href points at,
// and where inside the chapter document the locator lands.

/**
 * Find the spine index matching an href.
 *
 * Spine hrefs are fragment-free file paths, but incoming hrefs may still
 * carry an anchor ("chapter.html#section") — compare file-to-file.
 * @param {Array} spineItems - Array of {href, url, ...}
 * @param {string} href
 * @returns {number} - Spine index, or -1
 */
export function findSpineIndexByHref(spineItems, href) {
  const target = (href || "").split("#")[0];
  if (!target) return -1;

  for (let i = 0; i < spineItems.length; i++) {
    const item = spineItems[i];
    if (
      item.href === target ||
      target.endsWith(item.href) ||
      item.href.endsWith(target)
    ) {
      return i;
    }
  }
  return -1;
}

/**
 * Vertical offset of a locator's target within its chapter document.
 *
 * Precedence: cssSelector (highlights carry one), then locations.fragments
 * (TOC anchors — calibre-split files hold several chapters, so landing at
 * file start would be the wrong chapter), then progression.
 * @param {Object} locator
 * @param {Document|null} doc - The chapter iframe's document
 * @param {number} chapterHeight - For progression-based offsets
 * @returns {number}
 */
export function offsetInChapter(locator, doc, chapterHeight) {
  const locations = locator?.locations || {};

  if (doc) {
    if (locations.cssSelector) {
      try {
        const element = doc.querySelector(locations.cssSelector);
        if (element) return element.getBoundingClientRect().top;
      } catch (e) {
        // Invalid selector; fall through.
      }
    }

    for (const fragment of locations.fragments || []) {
      const id = fragment.startsWith("#") ? fragment.slice(1) : fragment;
      const element = id ? doc.getElementById(id) : null;
      if (element) return element.getBoundingClientRect().top;
    }
  }

  if (typeof locations.progression === "number") {
    return chapterHeight * Math.max(0, Math.min(1, locations.progression));
  }
  return 0;
}
