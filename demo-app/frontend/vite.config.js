import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev proxies /api to the backend container; the production build is served by
// the backend itself, so /api is same-origin there.
export default defineConfig({
  plugins: [react()],
  build: { outDir: "dist", emptyOutDir: true },
  server: {
    host: true,
    proxy: { "/api": "http://localhost:8080" },
  },
});
