import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: '../Public',
    emptyOutDir: true,
    target: 'esnext',
    rollupOptions: {
      output: {
        manualChunks: {
          echarts: ['echarts', 'echarts-for-react'],
          vendor: ['react', 'react-dom', 'date-fns', 'lucide-react'],
        },
      },
    },
  },
  server: {
    port: 5173,
    proxy: {
      '/trends': 'https://edgar-exhibits.example.run.app',
      '/catalog': 'https://edgar-exhibits.example.run.app',
      '/filings': 'https://edgar-exhibits.example.run.app',
      '/schema': 'https://edgar-exhibits.example.run.app',
    },
  },
});
