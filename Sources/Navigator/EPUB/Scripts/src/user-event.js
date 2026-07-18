// DOM events cross WebKit content worlds. Authored page-world code can dispatch
// synthetic events into bridge-world listeners, but only the user agent can
// mark an event trusted. Older WebKit test doubles omit the property, so keep
// treating an absent value as trusted.
export function isUserEvent(event) {
  return event.isTrusted !== false;
}

export function addUserEventListener(target, eventName, listener, options) {
  target.addEventListener(
    eventName,
    (event) => {
      if (isUserEvent(event)) listener(event);
    },
    options
  );
}
