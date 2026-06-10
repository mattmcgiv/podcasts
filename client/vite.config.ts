/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  server: {
    host: true,
    proxy: {
      "/api": "http://127.0.0.1:8080",
    },
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
        lines: 80,
        statements: 80,
      },
    },
  },
});
