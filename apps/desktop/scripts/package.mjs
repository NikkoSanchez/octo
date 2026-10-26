// Builds a macOS app bundle: `dev` → "Octo Dev" (dev.octo.app.dev), `release` → "Octo"
// (dev.octo.app). Each channel pins its own data folder in the main process, independent of the name.
// Usage: node scripts/package.mjs <dev|release> [outputAppPath]
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build, Platform } from "electron-builder";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const channel = process.argv[2] === "release" ? "release" : "dev";
const destination = process.argv[3];
const identity = channel === "release"
  ? { productName: "Octo", appId: "dev.octo.app" }
  : { productName: "Octo Dev", appId: "dev.octo.app.dev" };

execFileSync(join(root, "node_modules/.bin/electron-vite"), ["build"], { cwd: root, stdio: "inherit", env: { ...process.env, OCTO_CHANNEL: channel } });

execFileSync(process.execPath, [resolve(root, "../../scripts/notices.mjs")], { cwd: root, stdio: "inherit" });

const output = join(root, "release", channel);
rmSync(output, { recursive: true, force: true });
await build({
  projectDir: root,
  publish: "never",
  targets: Platform.MAC.createTarget("dir"),
  config: {
    appId: identity.appId,
    productName: identity.productName,
    copyright: "Copyright © 2026 Nikkolas Sanchez",
    directories: { output, buildResources: "resources" },
    files: ["out/**/*", "package.json"],
    extraResources: [{ from: "../../THIRD_PARTY_NOTICES.md", to: "THIRD_PARTY_NOTICES.md" }, { from: "../../LICENSE", to: "LICENSE" }],
    asarUnpack: ["**/node_modules/node-pty/**"],
    npmRebuild: false,
    extraMetadata: { productName: identity.productName },
    mac: {
      icon: "resources/icon.icns",
      category: "public.app-category.developer-tools",
      // Ad hoc signing for local use; distribution signing and notarization are not configured.
      identity: "-",
      hardenedRuntime: false,
      gatekeeperAssess: false,
      target: "dir",
      extendInfo: {
        NSMicrophoneUsageDescription: "Web pages in the browser panel may ask to use the microphone.",
        NSCameraUsageDescription: "Web pages in the browser panel may ask to use the camera.",
      },
    },
  },
});

const built = join(output, process.arch === "arm64" ? "mac-arm64" : "mac", `${identity.productName}.app`);
if (!existsSync(built)) throw new Error(`Expected ${built}`);
if (destination) {
  rmSync(destination, { recursive: true, force: true });
  cpSync(built, destination, { recursive: true, verbatimSymlinks: true });
  console.log(`Built ${destination}`);
} else {
  console.log(`Built ${built}`);
}
