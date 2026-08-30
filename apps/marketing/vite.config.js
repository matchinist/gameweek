import { defineConfig } from 'vite';
import { resolve } from 'node:path';

const pages = ['contact', 'privacy', 'terms', 'pricingtest', 'cs2fantasy', 'welcome', 'reset', 'reset-password'];

export default defineConfig({
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      input: Object.fromEntries([
        ['index', resolve(import.meta.dirname, 'index.html')],
        ['notfound', resolve(import.meta.dirname, '404.html')],
        ...pages.map(p => [p, resolve(import.meta.dirname, p, 'index.html')]),
      ]),
    },
  },
});
