/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const viteBase =
  (globalThis as { process?: { env?: { VITE_BASE?: string } } }).process?.env?.VITE_BASE ?? "/";

export default defineConfig({
  base: viteBase,
  define: { __PODS_BUILD_ID__: JSON.stringify(crypto.randomUUID()) },
  plugins: [react(), {
    name: "pods-offline-assets",
    enforce: "post",
    generateBundle(_options, bundle) {
      const paths = [...new Set(["/index.html", "/manifest.webmanifest", "/icon.svg", ...Object.keys(bundle).filter(p => !p.endsWith(".map")).map(p => `/${p}`)])];
      this.emitFile({ type: "asset", fileName: "offline-assets.json", source: JSON.stringify(paths) });
    },
  }],
  build: {
    rollupOptions: {
      input: { main: "index.html", sw: "src/sw.ts" },
      output: { entryFileNames: chunk => chunk.name === "sw" ? "sw.js" : "assets/[name]-[hash].js" },
    },
  },
  server: {
    host: true,
  },
  test: {
    environment: "jsdom",
    setupFiles: "./src/test/setup.ts",
    restoreMocks: true,
    coverage: {
      provider: "v8",
      include: ["src/**"],
      exclude: ["src/test/**", "src/types.ts", "src/main.tsx"],
      thresholds: {
        lines: 90,
        statements: 90,
        functions: 90,
      },
    },
  },
});
