import { defineConfig } from 'vite';
import { resolve } from 'node:path';

export default defineConfig({
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      input: {
        standings: resolve(import.meta.dirname, 'standings/index.html'),
        'top-scorers': resolve(import.meta.dirname, 'top-scorers/index.html'),
        'squad-analytics': resolve(import.meta.dirname, 'squad-analytics/index.html'),
      },
    },
  },
});
