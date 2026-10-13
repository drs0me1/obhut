// Konsol's new shell (DD-258): npm ci && npm run derle writes ../../console/yeni/ (committed).
// Caddy serves it at /yeni/ under the console CSP (script-src/style-src 'self', img-src 'self' blob:,
// font-src 'self'), so the output has fixed file names, no inline script or style, no data: URIs and
// no source maps.
import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import { lisanslar } from "./lisanslar.mjs";

export default defineConfig({
  base: "/yeni/",
  plugins: [vue(), lisanslar()],
  define: {
    // Composition API only; no devtools or hydration details in the production bundle.
    __VUE_OPTIONS_API__: "false",
    __VUE_PROD_DEVTOOLS__: "false",
    __VUE_PROD_HYDRATION_MISMATCH_DETAILS__: "false",
  },
  build: {
    outDir: "../../console/yeni",
    emptyOutDir: true,
    assetsInlineLimit: 0,
    modulePreload: false,
    sourcemap: false,
    cssCodeSplit: false,
    reportCompressedSize: false,
    rolldownOptions: {
      output: {
        entryFileNames: "app.js",
        chunkFileNames: "[name].js",
        assetFileNames: (asset) => (asset.names.some((name) => name.endsWith(".css")) ? "app.css" : "assets/[name][extname]"),
      },
    },
  },
});
