import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vite-plus/test";

import {
  BUNDLE_NAMES,
  GLOBAL_MARKERS,
  STATIC_ASSET_NAMES,
} from "../scripts/bundle-manifest";
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
    if (!omit.includes(name)) {
      const content = extraEmpty.includes(name) ? "" : validContentFor(name);
      writeFileSync(join(dir, name), content);
    }

    const mapName = `${name}.map`;
    if (!omit.includes(mapName)) {
      const content = extraEmpty.includes(mapName) ? "" : '{"version":3}';
      writeFileSync(join(dir, mapName), content);
    }
  }

  for (const name of STATIC_ASSET_NAMES) {
    if (!omit.includes(name)) {
      const content = extraEmpty.includes(name)
        ? ""
        : "var cw = {}; cw.applyDecorations = function () {};";
      writeFileSync(join(dir, name), content);
    }
  }
}

const tempDirs = [];

afterEach(() => {
  while (tempDirs.length > 0) {
    rmSync(tempDirs.pop(), { recursive: true, force: true });
  }
});

describe("verifyBundles", () => {
  it("passes with exactly five bundles and five source maps", () => {
    const dir = makeTempOutDir();
    tempDirs.push(dir);
    writeValidBundleSet(dir);

    const verified = verifyBundles(dir);

    expect(verified).toHaveLength(5);
    for (const name of BUNDLE_NAMES) {
      expect(verified.some((p) => p.endsWith(name))).toBe(true);
    }
  });

  it("fails when the required static shim is missing", () => {
    const dir = makeTempOutDir();
    tempDirs.push(dir);
    writeValidBundleSet(dir, {
      omit: ["readium-continuous-wrapper-shim.js"],
    });

    expect(() => verifyBundles(dir)).toThrow(BundleVerificationError);
    expect(() => verifyBundles(dir)).toThrow(
      /readium-continuous-wrapper-shim\.js/
    );
  });

  it("fails when the required static shim is empty", () => {
    const dir = makeTempOutDir();
    tempDirs.push(dir);
    writeValidBundleSet(dir, {
      extraEmpty: ["readium-continuous-wrapper-shim.js"],
    });

    expect(() => verifyBundles(dir)).toThrow(BundleVerificationError);
    expect(() => verifyBundles(dir)).toThrow(
      /readium-continuous-wrapper-shim\.js is empty/
    );
  });

  it("fails when one expected bundle is missing", () => {
    const dir = makeTempOutDir();
    tempDirs.push(dir);
    writeValidBundleSet(dir, { omit: ["readium-fixed.js"] });

    expect(() => verifyBundles(dir)).toThrow(BundleVerificationError);
    expect(() => verifyBundles(dir)).toThrow(/readium-fixed\.js/);
  });

  it("fails when an expected source map is missing", () => {
    const dir = makeTempOutDir();
    tempDirs.push(dir);
    writeValidBundleSet(dir, { omit: ["readium-fixed.js.map"] });

    expect(() => verifyBundles(dir)).toThrow(BundleVerificationError);
    expect(() => verifyBundles(dir)).toThrow(/readium-fixed\.js\.map/);
  });

  it("fails when an unexpected hashed chunk is present", () => {
    const dir = makeTempOutDir();
    tempDirs.push(dir);
    writeValidBundleSet(dir);
    writeFileSync(join(dir, "readium-fixed-Cj8sN2kQ.js"), "/* chunk */");

    expect(() => verifyBundles(dir)).toThrow(BundleVerificationError);
    expect(() => verifyBundles(dir)).toThrow(/unexpected/);
  });

  it("fails when an unexpected non-JavaScript asset is present", () => {
    const dir = makeTempOutDir();
    tempDirs.push(dir);
    writeValidBundleSet(dir);
    writeFileSync(join(dir, "readium-fixed.css"), "/* unexpected */");

    expect(() => verifyBundles(dir)).toThrow(BundleVerificationError);
    expect(() => verifyBundles(dir)).toThrow(/readium-fixed\.css/);
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
