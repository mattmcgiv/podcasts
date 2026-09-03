/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const viteBase =
  (globalThis as { process?: { env?: { VITE_BASE?: string } } }).process?.env?.VITE_BASE ?? "/";

export default defineConfig({
  base: viteBase,
  plugins: [react()],
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
