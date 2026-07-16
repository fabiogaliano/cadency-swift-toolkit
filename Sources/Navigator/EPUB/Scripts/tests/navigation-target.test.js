import { describe, expect, it } from "vitest";
import {
  findSpineIndexByHref,
  offsetInChapter,
} from "../src/navigation-target";

const spineItems = [
  { href: "text/part0001.html" },
  { href: "text/part0024.html" },
  { href: "OEBPS/chapter3.xhtml" },
];

describe("findSpineIndexByHref", () => {
  it("matches an exact href", () => {
    expect(findSpineIndexByHref(spineItems, "text/part0024.html")).toBe(1);
  });

  it("matches a fragment-bearing href to its file", () => {
    expect(
      findSpineIndexByHref(spineItems, "text/part0024.html#_idParaDest-22")
    ).toBe(1);
  });

  it("matches by suffix in either direction", () => {
    expect(findSpineIndexByHref(spineItems, "/book/text/part0001.html")).toBe(
      0
    );
    expect(findSpineIndexByHref(spineItems, "chapter3.xhtml")).toBe(2);
  });

  it("returns -1 for empty and fragment-only hrefs instead of matching everything", () => {
    // "".endsWith("") is true; without the guard these would match index 0.
    expect(findSpineIndexByHref(spineItems, "")).toBe(-1);
    expect(findSpineIndexByHref(spineItems, null)).toBe(-1);
    expect(findSpineIndexByHref(spineItems, "#anchor")).toBe(-1);
  });

  it("returns -1 when nothing matches", () => {
    expect(findSpineIndexByHref(spineItems, "text/missing.html")).toBe(-1);
  });
});

describe("offsetInChapter", () => {
  const element = (top) => ({ getBoundingClientRect: () => ({ top }) });

  function doc({ byId = {}, bySelector = {} } = {}) {
    return {
      getElementById: (id) => byId[id] ?? null,
      querySelector: (selector) => {
        if (selector === "!!!") throw new Error("invalid selector");
        return bySelector[selector] ?? null;
      },
    };
  }

  it("uses the cssSelector element when present", () => {
    const locator = { locations: { cssSelector: "#p12", progression: 0.5 } };
    expect(
      offsetInChapter(
        locator,
        doc({ bySelector: { "#p12": element(420) } }),
        1000
      )
    ).toBe(420);
  });

  it("resolves fragments by element id, tolerating a leading #", () => {
    const chapterDoc = doc({ byId: { "_idParaDest-22": element(3100) } });
    expect(
      offsetInChapter(
        { locations: { fragments: ["_idParaDest-22"] } },
        chapterDoc,
        1000
      )
    ).toBe(3100);
    expect(
      offsetInChapter(
        { locations: { fragments: ["#_idParaDest-22"] } },
        chapterDoc,
        1000
      )
    ).toBe(3100);
  });

  it("tries fragments in order and skips ones that resolve to nothing", () => {
    const chapterDoc = doc({ byId: { second: element(900) } });
    expect(
      offsetInChapter(
        { locations: { fragments: ["page=12", "second"] } },
        chapterDoc,
        1000
      )
    ).toBe(900);
  });

  it("falls back from an invalid selector to fragments", () => {
    const chapterDoc = doc({ byId: { anchor: element(150) } });
    expect(
      offsetInChapter(
        { locations: { cssSelector: "!!!", fragments: ["anchor"] } },
        chapterDoc,
        1000
      )
    ).toBe(150);
  });

  it("falls back to progression, clamped to [0, 1]", () => {
    expect(
      offsetInChapter({ locations: { progression: 0.25 } }, doc(), 2000)
    ).toBe(500);
    expect(
      offsetInChapter({ locations: { progression: 1.7 } }, doc(), 2000)
    ).toBe(2000);
    expect(
      offsetInChapter(
        { locations: { fragments: ["missing"], progression: 0.5 } },
        doc(),
        2000
      )
    ).toBe(1000);
  });

  it("uses progression even without a document", () => {
    expect(
      offsetInChapter({ locations: { progression: 0.5 } }, null, 2000)
    ).toBe(1000);
  });

  it("is 0 with no usable locations", () => {
    expect(offsetInChapter({ locations: {} }, doc(), 1000)).toBe(0);
    expect(offsetInChapter(null, null, 1000)).toBe(0);
  });
});
