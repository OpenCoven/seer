import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

/**
 * Production build config for the standalone macOS renderer bundle.
 *
 * Emits a single self-contained `Renderer` folder with no source maps and no
 * absolute filesystem paths in the generated HTML/JS/CSS — `base: "./"`
 * keeps every emitted asset reference relative so the bundle can be loaded
 * from anywhere the native host serves it from (e.g. `seer://app/standalone-window.html`
 * resolving `./assets/...` against that same URL, not the filesystem root).
 */
export default defineConfig({
  base: "./",
  plugins: [react(), tailwindcss()],
  build: {
    outDir: "build/standalone-renderer/Renderer",
    emptyOutDir: true,
    sourcemap: false,
    rollupOptions: {
      input: "standalone-window.html",
    },
  },
});
