export interface FinitePoint {
  x: number;
  y: number;
}

export interface FiniteRect extends FinitePoint {
  width: number;
  height: number;
}

// Converts an iframe-local rect into top-level WKWebView viewport coordinates.
// The caller obtains the optional iframe offset from the DOM so this remains
// pure and does not accidentally add an outer document scroll offset.
export function toTopViewportRect(
  iframeLocalRect: FiniteRect,
  frameOffset: FinitePoint | undefined
): FiniteRect {
  if (frameOffset === undefined) {
    return iframeLocalRect;
  }

  return {
    x: iframeLocalRect.x + frameOffset.x,
    y: iframeLocalRect.y + frameOffset.y,
    width: iframeLocalRect.width,
    height: iframeLocalRect.height,
  };
}
