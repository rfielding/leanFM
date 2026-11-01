// Builds the browser app into ../cmd/demo/static/app/ (app.js, app.css), which the Go
// demo server embeds and serves under its strict content security policy.
import {defineConfig} from "vite";

export default defineConfig({
  define: {"process.env.NODE_ENV": JSON.stringify("production")},
  build: {
    outDir: "../cmd/demo/static/app",
    emptyOutDir: true,
    cssCodeSplit: false,
    lib: {entry: "src/main.tsx", name: "GoServerApp", formats: ["iife"], fileName: () => "app.js", cssFileName: "app"}
  }
});
