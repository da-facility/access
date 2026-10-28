import { defineConfig } from "vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [tanstackStart(), react()],
  resolve: { dedupe: ["react", "react-dom", "@stylexjs/stylex"] },
  ssr: { noExternal: ["@da-facility/ui", "@astryxdesign/core", "@astryxdesign/theme-neutral"] },
  server: { strictPort: true, allowedHosts: ["goran.tail7c7833.ts.net"] },
});
