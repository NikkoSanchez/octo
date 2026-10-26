import { resolve } from "node:path";
import react from "@vitejs/plugin-react";
import { defineConfig } from "electron-vite";

// Workspace packages export TypeScript source, so they are bundled rather than externalized.
const workspacePackages = ["@octo/core", "@octo/agents", "@octo/git"];
const channel = process.env.OCTO_CHANNEL === "release" ? "release" : "dev";

export default defineConfig({
  main: {
    build: {
      externalizeDeps: { exclude: [...workspacePackages, "immer"] },
      rollupOptions: { input: { index: resolve(__dirname, "src/main/index.ts") } },
    },
    define: { __OCTO_CHANNEL__: JSON.stringify(channel) },
  },
  preload: {
    build: {
      externalizeDeps: { exclude: workspacePackages },
      rollupOptions: {
        input: { index: resolve(__dirname, "src/preload/index.ts") },
        // Sandboxed preloads must be a single CommonJS file.
        output: { format: "cjs", entryFileNames: "[name].cjs" },
      },
    },
  },
  renderer: {
    root: resolve(__dirname, "src/renderer"),
    plugins: [react()],
    build: {
      rollupOptions: { input: { index: resolve(__dirname, "src/renderer/index.html") } },
    },
    worker: { format: "es" },
  },
});
