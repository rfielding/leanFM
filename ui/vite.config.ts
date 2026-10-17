import {defineConfig} from "vite";

export default defineConfig({
  define: {
    "process.env.NODE_ENV": JSON.stringify("production")
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    lib: {entry: "src/main.tsx", name: "LeanFMUI", formats: ["iife"], fileName: () => "react-app.js"}
  }
});
