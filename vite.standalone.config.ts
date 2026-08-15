import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import process from "node:process";

const privateOutDir = process.env.SEER_RENDERER_PRIVATE_OUT_DIR;
if (!privateOutDir) {
  throw new Error("SEER_RENDERER_PRIVATE_OUT_DIR must identify the lock owner's private generation");
}

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
    outDir: privateOutDir,
    emptyOutDir: true,
    sourcemap: false,
    rollupOptions: {
      input: "standalone-window.html",
    },
  },
});
