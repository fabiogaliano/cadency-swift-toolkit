//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import { isScrollModeEnabled } from "./utils";
import { getCssSelector } from "css-selector-generator";

// Single source of truth for what counts as "user interactive", shared by
// `findNearestInteractiveElement` (below) and `blocks.js`'s block-activation
// exclusion, so the two never drift into conflicting tag lists.
var interactiveTags = [
  "a",
  "audio",
  "button",
  "canvas",
  "details",
  "summary",
  "input",
  "label",
  "option",
  "select",
  "submit",
  "textarea",
  "video",
];

// Checks whether the element is editable by the user.
function isEditableElement(element) {
  return (
    element.hasAttribute("contenteditable") &&
    element.getAttribute("contenteditable").toLowerCase() != "false"
  );
}

// Returns `element` or its nearest ancestor (inclusive) considered "user
// interactive" - a link, control, editable region, or embedded media - or
// null. Walks up because the touch might be for example on an <em> inside
// an <a>.
export function findNearestInteractiveAncestor(element) {
  if (element == null) {
    return null;
  }

  if (interactiveTags.indexOf(element.nodeName.toLowerCase()) !== -1) {
    return element;
  }

  if (isEditableElement(element)) {
    return element;
  }

  if (element.parentElement) {
    return findNearestInteractiveAncestor(element.parentElement);
  }

  return null;
}

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
export function findFirstVisibleLocator() {
  const element = findElement(document.body);
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

function findElement(rootElement) {
  for (var i = 0; i < rootElement.children.length; i++) {
    const child = rootElement.children[i];
    if (!shouldIgnoreElement(child) && isElementVisible(child)) {
      return findElement(child);
    }
  }
  return rootElement;
}

function isElementVisible(element) {
  if (readium.isFixedLayout) return true;

  if (element === document.body || element === document.documentElement) {
    return true;
  }
  if (!document || !document.documentElement || !document.body) {
    return false;
  }

  const rect = element.getBoundingClientRect();
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
