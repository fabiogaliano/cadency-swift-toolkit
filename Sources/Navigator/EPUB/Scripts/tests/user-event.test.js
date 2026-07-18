import { describe, expect, it } from "vite-plus/test";

import { addUserEventListener, isUserEvent } from "../src/user-event";

describe("isUserEvent", () => {
  it("rejects synthetic DOM events", () => {
    expect(isUserEvent({ isTrusted: false })).toBe(false);
  });

  it("accepts browser events and legacy test doubles", () => {
    expect(isUserEvent({ isTrusted: true })).toBe(true);
    expect(isUserEvent({})).toBe(true);
  });

  it("filters synthetic events when registering listeners", () => {
    let listener;
    const target = {
      addEventListener(_eventName, callback) {
        listener = callback;
      },
    };
    const received = [];

    addUserEventListener(target, "wheel", (event) => received.push(event));
    listener({ isTrusted: false });
    listener({ isTrusted: true });

    expect(received).toEqual([{ isTrusted: true }]);
  });
});
