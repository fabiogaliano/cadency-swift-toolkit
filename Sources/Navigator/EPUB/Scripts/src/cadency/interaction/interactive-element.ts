const interactiveTags = new Set([
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
]);

export function isEditableElement(element: Element): boolean {
  if (!element.hasAttribute("contenteditable")) {
    return false;
  }

  const contentEditable = element.getAttribute("contenteditable");
  return contentEditable !== null && contentEditable.toLowerCase() !== "false";
}

// Returns `element` or its nearest ancestor (inclusive) considered "user
// interactive" - a link, control, editable region, or embedded media - or
// null. Walks up because the touch might be for example on an <em> inside
// an <a>.
export function findNearestInteractiveAncestor(
  element: Element | null
): Element | null {
  if (element === null) {
    return null;
  }

  if (interactiveTags.has(element.nodeName.toLowerCase())) {
    return element;
  }

  if (isEditableElement(element)) {
    return element;
  }

  return findNearestInteractiveAncestor(element.parentElement);
}
