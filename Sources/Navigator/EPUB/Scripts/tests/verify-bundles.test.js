import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vite-plus/test";

import { BUNDLE_NAMES, GLOBAL_MARKERS } from "../scripts/bundle-manifest";
import {
  BundleVerificationError,
  verifyBundles,
} from "../scripts/verify-bundles";

// Minimal content for each bundle name that satisfies its global-API marker,
// so tests can construct a "valid" output dir without a real build.
function validContentFor(name) {
  const marker = GLOBAL_MARKERS[name];
  if (/readium/.test(marker.source)) return "globalThis.readium = {};";
  if (/spread/.test(marker.source)) return "globalThis.spread = {};";
  return "globalThis.continuousWrapper = {};";
}

function makeTempOutDir() {
  return mkdtempSync(join(tmpdir(), "verify-bundles-"));
}

function writeValidBundleSet(dir, { omit = [], extraEmpty = [] } = {}) {
  for (const name of BUNDLE_NAMES) {
    if (omit.includes(name)) continue;
    const content = extraEmpty.includes(name) ? "" : validContentFor(name);
    writeFileSync(join(dir, name), content);
  }
}

const tempDirs = [];

afterEach(() => {
  while (tempDirs.length > 0) {
    rmSync(tempDirs.pop(), { recursive: true, force: true });
  }
});

describe("verifyBundles", () => {
  it("passes when the output dir has exactly the five expected bundles", () => {
    const dir = makeTempOutDir();
    tempDirs.push(dir);
    writeValidBundleSet(dir);

    const verified = verifyBundles(dir);

    expect(verified).toHaveLength(5);
    for (const name of BUNDLE_NAMES) {
      expect(verified.some((p) => p.endsWith(name))).toBe(true);
    }
  });

  it("passes when the known static shim sits alongside the five bundles", () => {
    const dir = makeTempOutDir();
    tempDirs.push(dir);
    writeValidBundleSet(dir);
    // Hand-authored, never regenerated - must not be mistaken for drift.
    writeFileSync(
      join(dir, "readium-continuous-wrapper-shim.js"),
      "(function () {})();"
    );

    expect(() => verifyBundles(dir)).not.toThrow();
  });

  it("fails when one expected bundle is missing", () => {
    const dir = makeTempOutDir();
    tempDirs.push(dir);
    writeValidBundleSet(dir, { omit: ["readium-fixed.js"] });

    expect(() => verifyBundles(dir)).toThrow(BundleVerificationError);
    expect(() => verifyBundles(dir)).toThrow(/readium-fixed\.js/);
  });

  it("fails when an unexpected hashed chunk is present", () => {
    const dir = makeTempOutDir();
    tempDirs.push(dir);
    writeValidBundleSet(dir);
    writeFileSync(join(dir, "readium-fixed-Cj8sN2kQ.js"), "/* chunk */");

    expect(() => verifyBundles(dir)).toThrow(BundleVerificationError);
    expect(() => verifyBundles(dir)).toThrow(/unexpected/);
  });

  it("fails when an expected bundle is empty", () => {
    const dir = makeTempOutDir();
    tempDirs.push(dir);
    writeValidBundleSet(dir, {
      extraEmpty: ["readium-continuous-wrapper.js"],
    });

    expect(() => verifyBundles(dir)).toThrow(BundleVerificationError);
    expect(() => verifyBundles(dir)).toThrow(
      /readium-continuous-wrapper\.js is empty/
    );
  });

  it("fails when the output directory does not exist", () => {
    const missingDir = join(tmpdir(), "verify-bundles-does-not-exist");
    expect(existsSync(missingDir)).toBe(false);

    expect(() => verifyBundles(missingDir)).toThrow(BundleVerificationError);
  });
});
