//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import { isScrollModeEnabled } from "./utils";
import { findNearestInteractiveAncestor } from "./cadency/interaction/interactive-element";
import { getCssSelector } from "css-selector-generator";

// Returns `element` or its first parent that is considered "user interactive".
// For example a link, a video clip or a text field.
//
// See. https://github.com/JayPanoz/architecture/tree/touch-handling/misc/touch-handling
export function findNearestInteractiveElement(element) {
  var interactive = findNearestInteractiveAncestor(element);
  return interactive ? interactive.outerHTML : null;
}

/// Returns the `Locator` object to the first block element that is visible on
/// the screen.
///
/// The visibility window defaults to this document's own viewport. An
/// embedding host (the continuous wrapper's full-height chapter iframes)
/// passes the on-screen slice in document-local coordinates instead — there
/// this window spans the whole chapter, so its own innerHeight would count
/// every element as visible and always anchor the chapter's first block.
export function findFirstVisibleLocator(visibleTop, visibleBottom) {
  const element = findElement(document.body, visibleTop, visibleBottom);
  return {
    href: "#",
    type: "application/xhtml+xml",
    locations: {
      cssSelector: getCssSelector(element),
    },
    text: {
      highlight: element.textContent,
    },
  };
}

function findElement(rootElement, visibleTop, visibleBottom) {
  for (var i = 0; i < rootElement.children.length; i++) {
    const child = rootElement.children[i];
    if (
      !shouldIgnoreElement(child) &&
      isElementVisible(child, visibleTop, visibleBottom)
    ) {
      return findElement(child, visibleTop, visibleBottom);
    }
  }
  return rootElement;
}

function isElementVisible(element, visibleTop, visibleBottom) {
  if (readium.isFixedLayout) return true;

  if (element === document.body || element === document.documentElement) {
    return true;
  }
  if (!document || !document.documentElement || !document.body) {
    return false;
  }

  const rect = element.getBoundingClientRect();
  if (typeof visibleTop === "number" && typeof visibleBottom === "number") {
    // The host's slice is always a vertical window, independent of this
    // document's own scroll/pagination mode.
    return rect.bottom > visibleTop && rect.top < visibleBottom;
  }
  if (isScrollModeEnabled()) {
    return rect.bottom > 0 && rect.top < window.innerHeight;
  } else {
    return rect.right > 0 && rect.left < window.innerWidth;
  }
}

function shouldIgnoreElement(element) {
  const elStyle = getComputedStyle(element);
  if (elStyle) {
    const display = elStyle.getPropertyValue("display");
    if (display != "block") {
      return true;
    }
    // Cannot be relied upon, because web browser engine reports invisible when out of view in
    // scrolled columns!
    // const visibility = elStyle.getPropertyValue("visibility");
    // if (visibility === "hidden") {
    //     return false;
    // }
    const opacity = elStyle.getPropertyValue("opacity");
    if (opacity === "0") {
      return true;
    }
  }

  return false;
}
