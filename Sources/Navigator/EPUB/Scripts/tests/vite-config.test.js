import { afterEach, describe, expect, it } from "vite-plus/test";

import config from "../vite.config";
import { resolveBundleOutDir } from "../scripts/bundle-manifest";

const originalArgv = [...process.argv];
const originalBundleOutDir = process.env.BUNDLE_OUT_DIR;

function configFor(mode) {
  if (typeof config !== "function") {
    throw new Error("Expected the Vite configuration to be a function");
  }
  return config({
    command: "build",
    mode,
    isSsrBuild: false,
    isPreview: false,
  });
}

afterEach(() => {
  process.argv.splice(0, process.argv.length, ...originalArgv);
  if (originalBundleOutDir === undefined) {
    delete process.env.BUNDLE_OUT_DIR;
  } else {
    process.env.BUNDLE_OUT_DIR = originalBundleOutDir;
  }
});

describe.sequential("engine Vite configuration", () => {
  it("keeps Vite+'s development-mode config probe build-free", () => {
    process.argv.splice(0, process.argv.length, "node", "vp", "check");

    expect(configFor("development").build).toBeUndefined();
  });

  it("rejects development mode on a direct build", () => {
    process.argv.splice(0, process.argv.length, "node", "vp", "build");

    expect(() => configFor("development")).toThrow(
      /Unknown or missing build mode "development"/
    );
  });

  it("resolves a relative output override identically for build and verification", () => {
    process.argv.splice(0, process.argv.length, "node", "vp", "build");
    process.env.BUNDLE_OUT_DIR = "tmp/rehearsal";

    const resolved = configFor("reflowable");

    expect(resolved.build?.outDir).toBe(
      resolveBundleOutDir(process.env.BUNDLE_OUT_DIR)
    );
  });
});
