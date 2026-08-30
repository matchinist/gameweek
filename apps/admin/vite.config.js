import { defineConfig } from 'vite';

// Phase 2.1: passthrough build — the page is a single classic-script HTML
// file, so vite emits it unchanged (parity-test.sh enforces byte identity).
// The module graph starts growing in 2.2+.
export default defineConfig({
  build: { outDir: 'dist', emptyOutDir: true },
});
