import { describe, expect, it } from "vite-plus/test";

import {
  addUserEventListener,
  isUserEvent,
  type UserEvent,
  type UserEventTarget,
} from "../../../src/cadency/interaction/user-event";

describe("isUserEvent", () => {
  it("rejects synthetic DOM events", () => {
    expect(isUserEvent({ isTrusted: false })).toBe(false);
  });

  it("accepts browser events and legacy test doubles", () => {
    expect(isUserEvent({ isTrusted: true })).toBe(true);
    expect(isUserEvent({})).toBe(true);
  });

  it("filters synthetic events without changing listener options or event identity", () => {
    type TestEvent = UserEvent & { readonly name: string };

    let registeredListener: ((event: TestEvent) => void) | undefined;
    let registeredOptions: boolean | AddEventListenerOptions | undefined;
    const target: UserEventTarget<TestEvent> = {
      addEventListener(_eventName, listener, options) {
        registeredListener = listener;
        registeredOptions = options;
      },
    };
    const options: AddEventListenerOptions = { capture: true, passive: false };
    const syntheticEvent: TestEvent = { isTrusted: false, name: "synthetic" };
    const browserEvent: TestEvent = { isTrusted: true, name: "browser" };
    const received: TestEvent[] = [];

    addUserEventListener(
      target,
      "wheel",
      (event) => received.push(event),
      options
    );

    if (registeredListener === undefined) {
      throw new Error("Expected addUserEventListener to register a listener");
    }

    registeredListener(syntheticEvent);
    registeredListener(browserEvent);

    expect(registeredOptions).toBe(options);
    expect(received).toEqual([browserEvent]);
    expect(received[0]).toBe(browserEvent);
  });
});
