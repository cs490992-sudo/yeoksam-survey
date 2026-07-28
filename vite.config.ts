import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'prompt',
      includeAssets: ['icon.svg'],
      manifest: {
        name: '역삼 만족도 조사',
        short_name: '역삼 조사',
        description: '역삼주간보호센터 만족도 조사',
        start_url: '/',
        display: 'standalone',
        theme_color: '#4c3b78',
        background_color: '#faf7f0',
        icons: [{ src: '/icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any maskable' }],
      },
      workbox: {
        navigateFallback: '/index.html',
        globPatterns: ['**/*.{js,css,html,svg}'],
        runtimeCaching: [],
      },
    }),
  ],
})
