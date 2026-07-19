export interface UserEvent {
  readonly isTrusted?: boolean;
}

export interface UserEventTarget<Event extends UserEvent> {
  addEventListener(
    eventName: string,
    listener: (event: Event) => void,
    options?: boolean | AddEventListenerOptions
  ): void;
}

// DOM events cross WebKit content worlds. Authored page-world code can dispatch
// synthetic events into bridge-world listeners, but only the user agent can
// mark an event trusted. Older WebKit test doubles omit the property, so keep
// treating an absent value as trusted.
export function isUserEvent(event: UserEvent): boolean {
  return event.isTrusted !== false;
}

export function addUserEventListener<Event extends UserEvent>(
  target: UserEventTarget<Event>,
  eventName: string,
  listener: (event: Event) => void,
  options?: boolean | AddEventListenerOptions
): void {
  target.addEventListener(
    eventName,
    (event) => {
      if (isUserEvent(event)) listener(event);
    },
    options
  );
}
