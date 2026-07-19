import { adjustPointToViewport } from "../../rect";
import { getCssSelector } from "css-selector-generator";

export interface FiniteFrame {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface TargetElementMetadata {
  tag: string;
  html: string | null;
  src: string | null;
  resourceHref: string | null;
  frame: FiniteFrame;
  accessibilityLabel: string | null;
  caption: string | null;
  cssSelector: string;
}

/**
 * Extracts metadata about the target element for gesture handling.
 *
 * Returns an object with the element's bounding rectangle, tag name, source
 * URL, a CSS selector, the href of the document that contains the element,
 * an accessibility label, and a caption. This information is used on the
 * Swift side to build the appropriate `ContentElement`.
 */
export function extractTargetElement(
  element: EventTarget | null
): TargetElementMetadata | null {
  if (!(element instanceof Element)) {
    return null;
  }

  const imageElement = findNearestImageElement(element);
  if (imageElement === null) {
    return null;
  }

  const rect = imageElement.getBoundingClientRect();
  // Adjust only the origin through the viewport transform; size is already
  // in viewport-relative units and does not depend on the frame offset.
  const adjustedOrigin = adjustPointToViewport({ x: rect.left, y: rect.top });

  const rawSrc =
    imageElement.getAttribute("src") ||
    imageElement.getAttribute("href") ||
    null;

  // Resolve the raw src/href attribute to an absolute URL using the document's
  // base URI. `getAttribute` returns the literal attribute value (possibly
  // relative), while we need the absolute form so Swift can relativize it
  // against the publication base URL to recover the correct manifest href.
  const src = rawSrc === null ? null : new URL(rawSrc, document.baseURI).href;

  // `html` is only needed for inline SVGs that have no resolvable `src`.
  const html = src === null ? imageElement.outerHTML : null;

  return {
    tag: imageElement.tagName.toLowerCase(),
    html,
    src,
    resourceHref: readium.link?.href ?? null,
    frame: {
      x: adjustedOrigin.x,
      y: adjustedOrigin.y,
      width: rect.width,
      height: rect.height,
    },
    accessibilityLabel: imageElement.getAttribute("aria-label")?.trim() || null,
    caption: extractCaption(imageElement),
    cssSelector: getCssSelector(imageElement),
  };
}

/**
 * Returns a human-readable caption for an image element by checking, in
 * order: the `alt` attribute, the `title` attribute, the text content of the
 * first SVG `<title>` child, the text content of the first SVG `<desc>`
 * child, and the text content of a `<figcaption>` inside a parent `<figure>`.
 * Returns `null` when none of these are present.
 *
 * When `alt` is present — even as an empty string (decorative image) — no
 * other source is consulted, so that an explicit `alt=""` suppresses fallback
 * captions rather than incorrectly propagating them.
 */
export function extractCaption(imageElement: Element): string | null {
  if (imageElement.hasAttribute("alt")) {
    const alt = imageElement.getAttribute("alt");
    return alt?.trim() || null;
  }

  const title = imageElement.getAttribute("title")?.trim();
  if (title) {
    return title;
  }

  const svgTitle = directChildText(imageElement, "title");
  if (svgTitle) {
    return svgTitle;
  }

  const svgDesc = directChildText(imageElement, "desc");
  if (svgDesc) {
    return svgDesc;
  }

  const figure = imageElement.closest("figure");
  if (figure) {
    const figcaption = figure.querySelector("figcaption")?.textContent?.trim();
    if (figcaption) {
      return figcaption;
    }
  }

  return null;
}

function directChildText(
  element: Element,
  selector: string
): string | undefined {
  return element.querySelector(`:scope > ${selector}`)?.textContent?.trim();
}

/**
 * Walks up the DOM tree from the given element to find the nearest image
 * element (img, svg).
 */
export function findNearestImageElement(element: Element): Element | null {
  const imageTags = new Set(["img", "svg"]);
  let current: Element | null = element;
  while (current !== null && current !== document.documentElement) {
    if (imageTags.has(current.tagName.toLowerCase())) {
      return current;
    }
    current = current.parentElement;
  }
  return null;
}
