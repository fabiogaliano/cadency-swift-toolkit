import { describe, expect, it } from "vite-plus/test";

import {
  DecorationRouting,
  type DecorationSnapshot,
} from "../../../src/cadency/continuous/decoration-routing";

const chapters = [{ href: "text/chapter1.xhtml" }, { href: "chapter2.xhtml" }];

function decoration(id: string, href: string): DecorationSnapshot {
  return {
    id,
    locator: { href, type: "application/xhtml+xml" },
    style: "highlight",
    element: "<div/>",
  };
}

describe("DecorationRouting", () => {
  it("routes snapshots with the existing fuzzy href matching", () => {
    const routing = new DecorationRouting();
    const first = decoration("first", "publication/text/chapter1.xhtml#quote");
    const second = decoration("second", "chapter2.xhtml");
    routing.replaceGroup("highlights", [first, second]);

    expect(routing.decorationsForSpineIndex(chapters, "highlights", 0)).toEqual(
      [first]
    );
    expect(routing.decorationsForSpineIndex(chapters, "highlights", 1)).toEqual(
      [second]
    );
  });

  it("replaces a group's complete snapshot including with an empty group", () => {
    const routing = new DecorationRouting();
    routing.replaceGroup("highlights", [decoration("first", "chapter2.xhtml")]);
    routing.replaceGroup("highlights", []);

    expect(routing.decorationsForSpineIndex(chapters, "highlights", 1)).toEqual(
      []
    );
  });

  it("replays the latest complete snapshots to later mounts", () => {
    const routing = new DecorationRouting();
    const current = decoration("current", "chapter2.xhtml");
    routing.replaceGroup("highlights", [current]);
    const replayed: Array<{
      groupName: string;
      decorations: readonly DecorationSnapshot[];
    }> = [];

    routing.forEachGroup((decorations, groupName) => {
      replayed.push({ groupName, decorations });
    });

    expect(replayed).toEqual([
      { groupName: "highlights", decorations: [current] },
    ]);
  });

  it("tracks activable-group membership", () => {
    const routing = new DecorationRouting();

    routing.setGroupActivable("highlights", true);
    expect(routing.isGroupActivable("highlights")).toBe(true);
    routing.setGroupActivable("highlights", false);
    expect(routing.isGroupActivable("highlights")).toBe(false);
  });
});
