//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// Script for the continuous scroll wrapper document.
// This orchestrates multiple chapter iframes for vertical continuous scrolling.

import { log } from "./utils";

// Polyfill for ResizeObserver on older iOS versions
import { ResizeObserver as ResizeObserverPolyfill } from "@juggle/resize-observer";
const ResizeObserver = window.ResizeObserver || ResizeObserverPolyfill;

// ============================================================================
// State
// ============================================================================

// Spine items configuration from Swift
let spineItems = [];

// Map of spine index -> chapter state
// State can be: 'spacer', 'loading', 'loaded', 'error'
const chapterStates = new Map();

// Map of spine index -> measured content height
const chapterHeights = new Map();

// Map of spine index -> iframe element
const loadedIframes = new Map();

// Configuration
let config = {
  // How many chapters to keep mounted behind current
  prefetchBehind: 1,
  // How many chapters to keep mounted ahead of current
  prefetchAhead: 2,
  // Maximum total mounted iframes
  maxMounted: 7,
  // Default height for spacers (estimated)
  defaultChapterHeight: 800,
};

// Current active chapter index (most visible)
let activeChapterIndex = 0;

// Scroll anchoring state
let anchorElement = null;
let anchorOffset = 0;
let suppressAnchoringUntil = 0;

let programmaticScrollUntil = 0;
let isUserScrolling = false;
let userScrollEndTimer = null;
let lastScrollY = 0;
let lastScrollTime = 0;
let estimatedCenterIndex = 0;
let lastEstimatedCenterIndexComputationTime = 0;
const pendingIframeHeightUpdates = new Map();

// Intersection observer for visibility tracking
let visibilityObserver = null;

function suppressAnchoringFor(durationMs) {
  const until = Date.now() + durationMs;
  suppressAnchoringUntil = Math.max(suppressAnchoringUntil, until);
}

function isAnchoringSuppressed() {
  return Date.now() < suppressAnchoringUntil;
}

function markProgrammaticScroll(durationMs = 250) {
  const until = Date.now() + durationMs;
  programmaticScrollUntil = Math.max(programmaticScrollUntil, until);
}

function isProgrammaticScrollActive() {
  return Date.now() < programmaticScrollUntil;
}

function withProgrammaticScroll(fn, durationMs = 250) {
  markProgrammaticScroll(durationMs);
  return fn();
}

function computeCenterChapterIndexFromHeights() {
  const centerY = window.scrollY + window.innerHeight / 2;
  let cumulative = 0;
  for (let i = 0; i < spineItems.length; i++) {
    cumulative += chapterHeights.get(i) || config.defaultChapterHeight;
    if (cumulative > centerY) return i;
  }
  return Math.max(0, spineItems.length - 1);
}

function applyIframeHeightChange(spineIndex, iframe, newHeight) {
  const previousHeight = chapterHeights.get(spineIndex) || 0;
  if (newHeight === previousHeight) return;

  if (isUserScrolling) {
    pendingIframeHeightUpdates.set(spineIndex, newHeight);
    return;
  }

  const needsAnchor =
    !isAnchoringSuppressed() && isChapterAboveViewport(spineIndex);
  if (needsAnchor) {
    saveScrollAnchor();
  }

  chapterHeights.set(spineIndex, newHeight);
  iframe.style.height = `${newHeight}px`;

  if (needsAnchor) {
    restoreScrollAnchor();
  }
}

function flushAfterUserScroll() {
  if (isUserScrolling) return;

  pendingIframeHeightUpdates.forEach((newHeight, spineIndex) => {
    const iframe = loadedIframes.get(spineIndex);
    if (!iframe) return;
    applyIframeHeightChange(spineIndex, iframe, newHeight);
  });
  pendingIframeHeightUpdates.clear();

  const centerIndex = computeCenterChapterIndexFromHeights();
  estimatedCenterIndex = centerIndex;
  activeChapterIndex = centerIndex;
  updateMountedChapters(centerIndex);
  notifyProgressionChanged();
}

// ============================================================================
// Initialization
// ============================================================================

/**
 * Initialize the continuous wrapper with spine items.
 * @param {Array} items - Array of {href, url, title, spineIndex}
 * @param {Object} options - Configuration options
 */
function initialize(items, options = {}) {
  spineItems = items;
  Object.assign(config, options);

  const container = document.getElementById("chapters");
  container.innerHTML = "";

  // Create spacer elements for all chapters
  items.forEach((item, index) => {
    const chapter = createChapterElement(index);
    container.appendChild(chapter);
    chapterStates.set(index, "spacer");
    chapterHeights.set(index, config.defaultChapterHeight);
  });

  setupVisibilityObserver();
  setupScrollListener();

  webkit.messageHandlers.spreadLoadStarted.postMessage({});

  // Load initial chapters around position 0
  updateMountedChapters(0);
}

/**
 * Creates a chapter container element (initially as a spacer).
 */
function createChapterElement(spineIndex) {
  const item = spineItems[spineIndex];

  const wrapper = document.createElement("div");
  wrapper.className = "chapter";
  wrapper.dataset.spineIndex = spineIndex;
  wrapper.dataset.href = item.href;

  // Create spacer initially
  const spacer = document.createElement("div");
  spacer.className = "chapter-spacer";
  spacer.style.height = `${config.defaultChapterHeight}px`;
  wrapper.appendChild(spacer);

  return wrapper;
}

// ============================================================================
// Chapter Loading/Unloading
// ============================================================================

/**
 * Mount an iframe for a chapter.
 */
function mountChapter(spineIndex) {
  if (
    chapterStates.get(spineIndex) === "loaded" ||
    chapterStates.get(spineIndex) === "loading"
  ) {
    return;
  }

  const item = spineItems[spineIndex];
  if (!item) return;

  const wrapper = getChapterWrapper(spineIndex);
  if (!wrapper) return;

  if (!isUserScrolling) {
    // Save scroll anchor before DOM changes
    saveScrollAnchor();
  }

  chapterStates.set(spineIndex, "loading");

  // Replace spacer with loading indicator
  wrapper.innerHTML = "";
  wrapper.style.minHeight = `${
    chapterHeights.get(spineIndex) || config.defaultChapterHeight
  }px`;
  const loading = document.createElement("div");
  loading.className = "chapter-loading";
  loading.textContent = "Loading...";
  wrapper.appendChild(loading);

  // Create iframe
  const iframe = document.createElement("iframe");
  iframe.className = "chapter-iframe";
  iframe.dataset.spineIndex = spineIndex;
  iframe.dataset.href = item.href;
  // Hide iframe until loaded
  iframe.style.opacity = "0";
  iframe.style.height = `${
    chapterHeights.get(spineIndex) || config.defaultChapterHeight
  }px`;

  iframe.addEventListener("load", () => {
    onIframeLoaded(spineIndex, iframe);
  });

  iframe.addEventListener("error", () => {
    onIframeError(spineIndex);
  });

  wrapper.appendChild(iframe);
  iframe.src = item.url;

  loadedIframes.set(spineIndex, iframe);

  if (!isUserScrolling) {
    // Restore scroll anchor after DOM changes
    restoreScrollAnchor();
  }
}

/**
 * Handle iframe load completion.
 */
function onIframeLoaded(spineIndex, iframe) {
  const wrapper = getChapterWrapper(spineIndex);
  if (!wrapper) return;

  // Remove loading indicator
  const loading = wrapper.querySelector(".chapter-loading");
  if (loading) {
    loading.remove();
  }

  wrapper.style.minHeight = "";

  chapterStates.set(spineIndex, "loaded");

  // Setup height observation
  setupIframeHeightObserver(spineIndex, iframe);

  // Inject link info into iframe
  const item = spineItems[spineIndex];
  try {
    const readium = getIframeReadium(iframe);
    if (readium) {
      readium.link = item.link || { href: item.href };
    }
  } catch (e) {
    // Cross-origin or security error, ignore
  }

  applyStoredSettingsToIframe(spineIndex, iframe);

  // Show iframe
  iframe.style.opacity = "1";

  // Decorations were already reapplied above via applyStoredSettingsToIframe;
  // this only notifies native so the mount reaches the navigator delegate.
  notifyChapterMounted(spineIndex);

  // Check if all initial chapters are loaded
  checkInitialLoadComplete();
}

/**
 * Handle iframe load error.
 */
function onIframeError(spineIndex) {
  const wrapper = getChapterWrapper(spineIndex);
  if (!wrapper) return;

  chapterStates.set(spineIndex, "error");

  wrapper.style.minHeight = "";

  wrapper.innerHTML = "";
  const error = document.createElement("div");
  error.className = "chapter-error";
  error.textContent = "Failed to load chapter";
  wrapper.appendChild(error);

  webkit.messageHandlers.logError.postMessage({
    message: `Failed to load chapter at spine index ${spineIndex}`,
  });
}

/**
 * Unmount an iframe and replace with spacer.
 */
function unmountChapter(spineIndex) {
  const state = chapterStates.get(spineIndex);
  if (state === "spacer") return;

  const wrapper = getChapterWrapper(spineIndex);
  if (!wrapper) return;

  // Save scroll anchor before DOM changes
  saveScrollAnchor();

  const height =
    wrapper.offsetHeight ||
    chapterHeights.get(spineIndex) ||
    config.defaultChapterHeight;
  chapterHeights.set(spineIndex, height);

  // Replace with spacer
  wrapper.innerHTML = "";
  const spacer = document.createElement("div");
  spacer.className = "chapter-spacer";
  spacer.style.height = `${height}px`;
  wrapper.appendChild(spacer);

  chapterStates.set(spineIndex, "spacer");
  loadedIframes.delete(spineIndex);

  if (!isUserScrolling) {
    // Restore scroll anchor
    restoreScrollAnchor();
  }
}

/**
 * Get the wrapper element for a chapter by spine index.
 */
function getChapterWrapper(spineIndex) {
  return document.querySelector(`.chapter[data-spine-index="${spineIndex}"]`);
}

function getIframeReadium(iframe) {
  const win = iframe?.contentWindow;
  return win?.readium;
}

function getIframeScrollHeight(iframe) {
  const doc = iframe?.contentDocument;
  if (!doc) return null;
  const bodyHeight = doc.body?.scrollHeight;
  const docHeight = doc.documentElement?.scrollHeight;
  return Math.max(bodyHeight || 0, docHeight || 0);
}

function applyStoredSettingsToIframe(spineIndex, iframe) {
  const readium = getIframeReadium(iframe);
  if (!readium) return;

  if (window._decorationTemplates) {
    try {
      readium.registerDecorationTemplates(window._decorationTemplates);
    } catch (e) {
      // Iframe readium not ready; templates reapply on next mount.
    }
  }

  if (window._cssProperties) {
    try {
      readium.setCSSProperties(window._cssProperties);
    } catch (e) {
      // Iframe readium not ready; properties reapply on next mount.
    }
  }

  const item = spineItems[spineIndex];
  if (!item) return;

  // Reapply each group's current snapshot subset for this chapter. A group whose
  // snapshot no longer covers this chapter resolves to an empty set and clears,
  // so decorations removed while the chapter was unmounted do not reappear.
  groupDecorations.forEach((decorations, groupName) => {
    applyDecorationsToIframe(
      iframe,
      groupName,
      decorationsForSpineIndex(decorations, spineIndex)
    );
  });
}

// ============================================================================
// Iframe Height Management
// ============================================================================

/**
 * Setup height observation for an iframe.
 */
function setupIframeHeightObserver(spineIndex, iframe) {
  try {
    const doc = iframe.contentDocument;
    if (!doc || !doc.body) return;

    // Initial height measurement
    updateIframeHeight(spineIndex, iframe);

    let rafId = null;
    const scheduleUpdate = () => {
      if (rafId != null) return;
      rafId = requestAnimationFrame(() => {
        rafId = null;
        updateIframeHeight(spineIndex, iframe);
      });
    };

    // Observe body resize
    const observer = new ResizeObserver(() => {
      scheduleUpdate();
    });
    observer.observe(doc.body);

    // Wait for fonts to load
    if (doc.fonts && doc.fonts.ready) {
      doc.fonts.ready.then(() => {
        scheduleUpdate();
      });
    }

    // Also observe document element for more accurate sizing
    if (doc.documentElement) {
      observer.observe(doc.documentElement);
    }
  } catch (e) {
    // Security error accessing iframe content
    log("Could not setup height observer for iframe:", e.message);
  }
}

/**
 * Update iframe height based on its content.
 */
function updateIframeHeight(spineIndex, iframe) {
  try {
    const doc = iframe.contentDocument;
    if (!doc || !doc.body) return;

    const previousHeight = chapterHeights.get(spineIndex) || 0;

    // Get the scroll height of the body
    const bodyHeight = doc.body.scrollHeight;
    const docHeight = doc.documentElement.scrollHeight;
    const newHeight = Math.max(bodyHeight, docHeight, 100);

    if (newHeight !== previousHeight) {
      const shouldDefer =
        isUserScrolling &&
        !isProgrammaticScrollActive() &&
        isChapterAboveViewport(spineIndex);
      if (shouldDefer) {
        pendingIframeHeightUpdates.set(spineIndex, newHeight);
        return;
      }

      // Save anchor before height change
      const needsAnchor =
        !isUserScrolling &&
        !isAnchoringSuppressed() &&
        isChapterAboveViewport(spineIndex);
      if (needsAnchor) {
        saveScrollAnchor();
      }

      chapterHeights.set(spineIndex, newHeight);
      iframe.style.height = `${newHeight}px`;

      // Restore anchor after height change
      if (needsAnchor) {
        restoreScrollAnchor();
      }
    }
  } catch (e) {
    // Security error
  }
}

/**
 * Check if a chapter is above the current viewport.
 */
function isChapterAboveViewport(spineIndex) {
  const wrapper = getChapterWrapper(spineIndex);
  if (!wrapper) return false;

  const rect = wrapper.getBoundingClientRect();
  return rect.bottom < 0;
}

// ============================================================================
// Scroll Anchoring
// ============================================================================

/**
 * Save the current scroll anchor element and offset.
 */
function saveScrollAnchor() {
  if (isUserScrolling) return;
  if (isAnchoringSuppressed()) return;

  // Find the first visible element to use as anchor
  const chapters = document.querySelectorAll(".chapter");

  for (const chapter of chapters) {
    const rect = chapter.getBoundingClientRect();
    if (rect.bottom > 0) {
      anchorElement = chapter;
      anchorOffset = rect.top + window.scrollY;
      return;
    }
  }
}

/**
 * Restore scroll position based on saved anchor.
 */
function restoreScrollAnchor() {
  if (!anchorElement) return;

  if (isUserScrolling) {
    anchorElement = null;
    anchorOffset = 0;
    return;
  }

  if (isAnchoringSuppressed()) {
    anchorElement = null;
    anchorOffset = 0;
    return;
  }

  const rect = anchorElement.getBoundingClientRect();
  const currentTop = rect.top + window.scrollY;
  const drift = currentTop - anchorOffset;

  if (Math.abs(drift) > 1) {
    withProgrammaticScroll(() => window.scrollBy(0, drift), 150);
  }

  anchorElement = null;
  anchorOffset = 0;
}

// ============================================================================
// Visibility Detection
// ============================================================================

/**
 * Setup IntersectionObserver for visibility tracking.
 */
function setupVisibilityObserver() {
  visibilityObserver = new IntersectionObserver(
    (entries) => {
      let maxVisibleRatio = 0;
      let mostVisibleIndex = activeChapterIndex;

      entries.forEach((entry) => {
        const spineIndex = parseInt(entry.target.dataset.spineIndex, 10);
        if (entry.intersectionRatio > maxVisibleRatio) {
          maxVisibleRatio = entry.intersectionRatio;
          mostVisibleIndex = spineIndex;
        }
      });

      if (mostVisibleIndex !== activeChapterIndex) {
        activeChapterIndex = mostVisibleIndex;
        onActiveChapterChanged(mostVisibleIndex);
      }
    },
    {
      threshold: [0, 0.1, 0.25, 0.5, 0.75, 1.0],
    }
  );

  // Observe all chapter wrappers
  document.querySelectorAll(".chapter").forEach((wrapper) => {
    visibilityObserver.observe(wrapper);
  });
}

/**
 * Setup scroll listener for progression updates.
 */
function setupScrollListener() {
  let ticking = false;

  lastScrollY = window.scrollY;
  lastScrollTime = Date.now();
  estimatedCenterIndex = activeChapterIndex;

  function maybeSuppressAnchoringFromClientX(clientX) {
    if (typeof clientX !== "number") return;
    if (clientX > window.innerWidth - 30) {
      suppressAnchoringFor(750);
    }
  }

  window.addEventListener(
    "touchstart",
    (e) => {
      const t = e.touches && e.touches[0];
      maybeSuppressAnchoringFromClientX(t?.clientX);
    },
    { passive: true }
  );

  window.addEventListener(
    "mousedown",
    (e) => {
      maybeSuppressAnchoringFromClientX(e.clientX);
    },
    { passive: true }
  );

  window.addEventListener("scroll", () => {
    if (!ticking) {
      requestAnimationFrame(() => {
        onScroll();
        ticking = false;
      });
      ticking = true;
    }
  });
}

/**
 * Handle scroll events.
 */
function onScroll() {
  const now = Date.now();
  const currentY = window.scrollY;
  const deltaY = Math.abs(currentY - lastScrollY);
  const deltaTime = now - lastScrollTime;

  lastScrollY = currentY;
  lastScrollTime = now;

  if (!isProgrammaticScrollActive()) {
    const velocity = deltaTime > 0 ? deltaY / deltaTime : 0;
    const isJumpLike =
      deltaY > window.innerHeight ||
      (velocity > 10 && deltaY > window.innerHeight * 0.25);

    if (isJumpLike) {
      if (!isUserScrolling) {
        estimatedCenterIndex = computeCenterChapterIndexFromHeights();
        activeChapterIndex = estimatedCenterIndex;
        lastEstimatedCenterIndexComputationTime = now;
      }

      isUserScrolling = true;
      clearTimeout(userScrollEndTimer);
      userScrollEndTimer = setTimeout(() => {
        isUserScrolling = false;
        flushAfterUserScroll();
      }, 150);

      const isLargeJump = deltaY > window.innerHeight * 2;
      if (isLargeJump && now - lastEstimatedCenterIndexComputationTime > 120) {
        estimatedCenterIndex = computeCenterChapterIndexFromHeights();
        activeChapterIndex = estimatedCenterIndex;
        lastEstimatedCenterIndexComputationTime = now;
      }
    }
  }

  const centerIndex = isUserScrolling
    ? estimatedCenterIndex
    : activeChapterIndex;
  updateMountedChapters(centerIndex);
  notifyProgressionChanged();
}

/**
 * Handle active chapter change.
 */
function onActiveChapterChanged(spineIndex) {
  updateMountedChapters(spineIndex);
  notifyProgressionChanged();
}

/**
 * Update which chapters are mounted based on the active chapter.
 */
function updateMountedChapters(centerIndex) {
  const start = Math.max(0, centerIndex - config.prefetchBehind);
  const end = Math.min(
    spineItems.length - 1,
    centerIndex + config.prefetchAhead
  );

  // Mount chapters in the window
  for (let i = start; i <= end; i++) {
    mountChapter(i);
  }

  if (isUserScrolling) {
    const maxMountedDuringFastScroll = Math.max(
      config.maxMounted * 2,
      config.maxMounted + 4
    );
    if (loadedIframes.size > maxMountedDuringFastScroll) {
      const mounted = [];
      loadedIframes.forEach((_, index) => {
        if (index < start || index > end) {
          mounted.push(index);
        }
      });

      mounted.sort((a, b) => {
        const distA = Math.abs(a - centerIndex);
        const distB = Math.abs(b - centerIndex);
        return distB - distA;
      });

      const toUnmount = mounted.slice(
        0,
        loadedIframes.size - maxMountedDuringFastScroll
      );
      toUnmount.forEach((index) => unmountChapter(index));
    }
    return;
  }

  // Unmount chapters outside the window (respecting maxMounted)
  const mounted = [];
  loadedIframes.forEach((_, index) => {
    if (index < start || index > end) {
      mounted.push(index);
    }
  });

  // If too many mounted, unmount furthest ones
  if (loadedIframes.size > config.maxMounted) {
    mounted.sort((a, b) => {
      const distA = Math.abs(a - centerIndex);
      const distB = Math.abs(b - centerIndex);
      return distB - distA; // Furthest first
    });

    const toUnmount = mounted.slice(0, loadedIframes.size - config.maxMounted);
    toUnmount.forEach((index) => unmountChapter(index));
  }
}

// ============================================================================
// Initial Load Tracking
// ============================================================================

let initialLoadComplete = false;

function checkInitialLoadComplete() {
  if (initialLoadComplete) return;

  // Check if all chapters in the initial window are loaded
  const centerIndex = 0;
  const start = Math.max(0, centerIndex - config.prefetchBehind);
  const end = Math.min(
    spineItems.length - 1,
    centerIndex + config.prefetchAhead
  );

  for (let i = start; i <= end; i++) {
    const state = chapterStates.get(i);
    if (state !== "loaded" && state !== "error") {
      return;
    }
  }

  initialLoadComplete = true;
  webkit.messageHandlers.spreadLoaded.postMessage({});
}

// ============================================================================
// Navigation
// ============================================================================

/**
 * Navigate to a specific locator.
 * @param {Object} locator - Locator object with href and locations
 * @returns {boolean} - Success
 */
function goTo(locator) {
  if (!locator) return false;

  // Find the target chapter by href
  const href = locator.href || "";
  let targetIndex = -1;

  for (let i = 0; i < spineItems.length; i++) {
    const item = spineItems[i];
    if (
      item.href === href ||
      href.endsWith(item.href) ||
      item.href.endsWith(href)
    ) {
      targetIndex = i;
      break;
    }
  }

  if (targetIndex === -1) {
    // Try to find by URL
    for (let i = 0; i < spineItems.length; i++) {
      if (
        spineItems[i].url &&
        locator.href &&
        spineItems[i].url.includes(locator.href)
      ) {
        targetIndex = i;
        break;
      }
    }
  }

  if (targetIndex === -1) {
    log("Could not find chapter for locator:", locator.href);
    return false;
  }

  // Ensure the chapter is mounted
  mountChapter(targetIndex);

  // Wait for chapter to be loaded, then scroll
  return scrollToLocatorInChapter(targetIndex, locator);
}

/**
 * Scroll to a locator within a specific chapter.
 */
function scrollToLocatorInChapter(spineIndex, locator) {
  const wrapper = getChapterWrapper(spineIndex);
  if (!wrapper) return false;

  const state = chapterStates.get(spineIndex);

  if (state === "loaded") {
    // Chapter is loaded, scroll to it
    const iframe = loadedIframes.get(spineIndex);
    if (iframe) {
      try {
        const wrapperTop = wrapper.getBoundingClientRect().top + window.scrollY;

        let offsetInChapter = 0;
        const iframeDoc = iframe.contentDocument;

        const selector = locator?.locations?.cssSelector;
        if (selector && iframeDoc) {
          try {
            const element = iframeDoc.querySelector(selector);
            if (element) {
              offsetInChapter = element.getBoundingClientRect().top;
            }
          } catch (e) {
            // Invalid selector; fall through to progression-based offset.
          }
        }

        const progression = locator?.locations?.progression;
        if (offsetInChapter === 0 && typeof progression === "number") {
          const chapterHeight =
            getIframeScrollHeight(iframe) ||
            chapterHeights.get(spineIndex) ||
            config.defaultChapterHeight;
          offsetInChapter =
            chapterHeight * Math.max(0, Math.min(1, progression));
        }

        withProgrammaticScroll(
          () =>
            window.scrollTo({
              top: wrapperTop + Math.max(0, offsetInChapter),
              behavior: "auto",
            }),
          250
        );

        return true;
      } catch (e) {
        // Fallback: just scroll to chapter start
        withProgrammaticScroll(
          () => wrapper.scrollIntoView({ behavior: "auto", block: "start" }),
          250
        );
        return true;
      }
    }
  } else if (state === "loading") {
    // Wait for load and retry
    setTimeout(() => scrollToLocatorInChapter(spineIndex, locator), 100);
    return true;
  } else {
    // Need to mount first
    mountChapter(spineIndex);
    setTimeout(() => scrollToLocatorInChapter(spineIndex, locator), 100);
    return true;
  }

  return false;
}

/**
 * Scroll forward by a viewport height.
 * @returns {boolean} - Whether scrolling occurred
 */
function scrollForward() {
  const currentY = window.scrollY;
  const maxY = document.documentElement.scrollHeight - window.innerHeight;

  if (currentY >= maxY - 1) {
    return false;
  }

  withProgrammaticScroll(
    () =>
      window.scrollBy({ top: window.innerHeight * 0.9, behavior: "smooth" }),
    1500
  );
  return true;
}

/**
 * Scroll backward by a viewport height.
 * @returns {boolean} - Whether scrolling occurred
 */
function scrollBackward() {
  const currentY = window.scrollY;

  if (currentY <= 1) {
    return false;
  }

  withProgrammaticScroll(
    () =>
      window.scrollBy({ top: -window.innerHeight * 0.9, behavior: "smooth" }),
    1500
  );
  return true;
}

// ============================================================================
// Location Reporting
// ============================================================================

/**
 * Find the first visible locator in the current view.
 * @returns {Object|null} - Locator object or null
 */
function findFirstVisibleLocator() {
  // Find the most visible loaded chapter
  let bestChapter = null;
  let bestVisibility = 0;

  loadedIframes.forEach((iframe, spineIndex) => {
    const wrapper = getChapterWrapper(spineIndex);
    if (!wrapper) return;

    const rect = wrapper.getBoundingClientRect();
    const viewportHeight = window.innerHeight;

    // Calculate visible portion
    const visibleTop = Math.max(0, rect.top);
    const visibleBottom = Math.min(viewportHeight, rect.bottom);
    const visibleHeight = Math.max(0, visibleBottom - visibleTop);

    if (visibleHeight > bestVisibility) {
      bestVisibility = visibleHeight;
      bestChapter = { spineIndex, iframe, wrapper, rect };
    }
  });

  if (!bestChapter) {
    return null;
  }

  const { spineIndex, iframe } = bestChapter;
  const item = spineItems[spineIndex];

  try {
    // Ask the iframe for its first visible locator
    const readium = getIframeReadium(iframe);
    const iframeLocator = readium?.findFirstVisibleLocator?.();

    if (iframeLocator) {
      // Adjust the locator href to be the actual resource href
      return {
        ...iframeLocator,
        href: item.href,
      };
    }
  } catch (e) {
    // Fallback: return chapter-level locator
  }

  // Fallback locator at chapter level
  return {
    href: item.href,
    type: "application/xhtml+xml",
    locations: {
      progression: 0,
    },
  };
}

/**
 * Notify native code about progression changes.
 */
function notifyProgressionChanged() {
  const totalHeight = document.documentElement.scrollHeight;
  const viewportHeight = window.innerHeight;
  const scrollY = window.scrollY;

  const maxY = Math.max(1, totalHeight - viewportHeight);
  const firstProgression = Math.max(0, Math.min(1, scrollY / maxY));
  const lastProgression = Math.max(
    0,
    Math.min(1, (scrollY + viewportHeight) / totalHeight)
  );

  webkit.messageHandlers.progressionChanged.postMessage({
    first: firstProgression,
    last: lastProgression,
    activeChapter: activeChapterIndex,
  });
}

/**
 * Notify native code that a chapter was mounted.
 */
function notifyChapterMounted(spineIndex) {
  webkit.messageHandlers.chapterMounted.postMessage({
    spineIndex: spineIndex,
    href: spineItems[spineIndex]?.href,
  });
}

// ============================================================================
// Decorations
// ============================================================================

// Latest complete decoration snapshot per group. Each applyDecorations call
// replaces a group's entry wholesale: a group is always the full set of
// decorations across every chapter, never a delta. Retained so chapters that
// mount (or remount) later reapply exactly this set and previously-removed
// decorations never reappear.
const groupDecorations = new Map();

// Decoration groups which should forward activation events.
const activableDecorationGroups = new Set();

// Decorations from `decorations` whose locator resolves to `spineIndex`, using
// the same fuzzy href matching the rest of the wrapper relies on.
function decorationsForSpineIndex(decorations, spineIndex) {
  return decorations.filter(
    (decoration) =>
      findSpineIndexByHref(decoration.locator?.href || "") === spineIndex
  );
}

/**
 * Apply a group's complete decoration snapshot.
 *
 * `decorations` is the full set for the group across all chapters. Every loaded
 * chapter is reconciled against it - including chapters with no decorations in
 * the snapshot, whose group is cleared - so removing a decoration (or passing an
 * empty array) takes effect everywhere, not just where a decoration still lives.
 * @param {string} groupName - Decoration group name
 * @param {Array} decorations - Complete decoration snapshot for the group
 */
function applyDecorations(groupName, decorations) {
  groupDecorations.set(groupName, decorations);

  loadedIframes.forEach((iframe, spineIndex) => {
    const state = chapterStates.get(spineIndex);
    if (state !== "loaded") {
      return;
    }
    applyDecorationsToIframe(
      iframe,
      groupName,
      decorationsForSpineIndex(decorations, spineIndex)
    );
  });
}

/**
 * Apply decorations to an iframe.
 */
function applyDecorationsToIframe(iframe, groupName, decorations) {
  try {
    const readium = getIframeReadium(iframe);
    if (!readium) return;
    const group = readium.getDecorations(groupName);
    group.clear();
    if (activableDecorationGroups.has(groupName)) {
      group.setActivable();
    }
    decorations.forEach((d) => group.add(d));
  } catch (e) {
    log("Failed to apply decorations:", e.message);
  }
}

/**
 * Find spine index by href.
 */
function findSpineIndexByHref(href) {
  for (let i = 0; i < spineItems.length; i++) {
    const item = spineItems[i];
    if (
      item.href === href ||
      href.endsWith(item.href) ||
      item.href.endsWith(href)
    ) {
      return i;
    }
  }
  return -1;
}

/**
 * Register decoration templates.
 */
function registerDecorationTemplates(templates) {
  // Apply templates to all loaded iframes
  loadedIframes.forEach((iframe) => {
    try {
      const readium = getIframeReadium(iframe);
      if (readium) {
        readium.registerDecorationTemplates(templates);
      }
    } catch (e) {
      // Ignore errors
    }
  });

  // Store for new iframes
  window._decorationTemplates = templates;
}

// ============================================================================
// CSS Properties
// ============================================================================

/**
 * Set CSS properties on all loaded iframes.
 */
function setCSSProperties(properties) {
  loadedIframes.forEach((iframe) => {
    try {
      const readium = getIframeReadium(iframe);
      if (readium) {
        readium.setCSSProperties(properties);
      }
    } catch (e) {
      // Ignore errors
    }
  });

  // Store the complete latest state for chapters mounted or remounted later.
  // View-model updates are deltas, so replacing this object would lose earlier
  // preferences after the sliding window unloads a chapter.
  window._cssProperties = {
    ...(window._cssProperties || {}),
    ...properties,
  };
}

// ============================================================================
// Chapter Separator Support
// ============================================================================

/**
 * Insert a separator before a chapter.
 * @param {number} spineIndex - Index of the chapter
 * @param {string} html - Separator HTML content
 */
function insertSeparator(spineIndex, html) {
  const wrapper = getChapterWrapper(spineIndex);
  if (!wrapper) return;

  // Check if separator already exists
  if (wrapper.previousElementSibling?.classList.contains("chapter-separator")) {
    return;
  }

  const separator = document.createElement("div");
  separator.className = "chapter-separator";
  separator.innerHTML = html;
  wrapper.parentNode.insertBefore(separator, wrapper);
}

function setDecorationGroupActivable(groupName, isActivable) {
  if (isActivable) {
    activableDecorationGroups.add(groupName);
  } else {
    activableDecorationGroups.delete(groupName);
  }
}

// ============================================================================
// Public API
// ============================================================================

global.continuousWrapper = {
  // Initialization
  initialize: initialize,

  // Navigation
  goTo: goTo,
  scrollForward: scrollForward,
  scrollBackward: scrollBackward,

  // Location
  findFirstVisibleLocator: findFirstVisibleLocator,

  // Decorations
  applyDecorations: applyDecorations,
  registerDecorationTemplates: registerDecorationTemplates,
  setDecorationGroupActivable: setDecorationGroupActivable,

  // CSS
  setCSSProperties: setCSSProperties,

  // Separators
  insertSeparator: insertSeparator,

  // Debug/info
  getActiveChapterIndex: () => activeChapterIndex,
  getChapterStates: () => Object.fromEntries(chapterStates),
  getChapterHeights: () => Object.fromEntries(chapterHeights),
};
