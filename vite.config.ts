import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
export default defineConfig({ plugins: [react(), tailwindcss()], publicDir: 'frontend-public', build: { sourcemap: false,rollupOptions:{output:{manualChunks(id){if(id.replace(/\\/g,'/').includes('/node_modules/@supabase/'))return 'supabase';}}} } });
