# Mobile UX, PWA and native packaging status

This document records what the browser application actually provides for phones and tablets, how it was verified,
and what is **not** included. It does not claim physical-device or native-Android testing.

## Implemented in this repository

- **Responsive shell** — the sidebar becomes an overlay drawer at `<= 760 px`. It closes on the close button,
  scrim (outside pointer), route change and `Escape`; body scroll is locked while open; focus returns to the menu
  button. The drawer footer keeps the signed-in profile, account settings, English/简体中文, light/dark theme,
  help, version and sign-out controls.
- **Bottom tab bar** — role-specific shortcuts sit above `env(safe-area-inset-bottom)`, and page content reserves
  bottom padding so the bar does not cover fields or actions.
- **Dialogs** — phones use a full-viewport dialog with a fixed header, independently scrollable body, sticky action
  row, safe-area padding and 16 px inputs (prevents iOS zoom). Primary dialog actions are at least 44 px tall.
- **Layouts** — record tables become cards on phones, chart cards remain readable, and route/watch screens do not
  introduce horizontal page scrolling.
- **Preferences** — dark and light themes, English and Simplified Chinese, reduced-motion support. The dark theme
  is the default; the action button always names the mode it will switch to.
- **PWA shell** — `frontend-public/manifest.webmanifest` (standalone, `start_url: /`, 192/512/maskable icons,
  theme colour), `frontend-public/sw.js`, and Apple/theme meta tags in `index.html`. `vite.config.ts` copies
  `frontend-public/` so the manifest, service worker and icons are served from the site root.
- **Service worker scope** — registered only in production builds. Navigation requests are network-first with a
  cached shell fallback. `/auth/`, `/rest/`, `/storage/` and `/functions/` requests are never cached. The worker
  does not cache business records, credentials or private files, and does not enable offline writes.

## Verification performed

- Playwright runs Chromium with three device profiles: desktop (1280×720), iPad Mini (768×1024) and Pixel 7
  (412×915). The complete browser suite covers authentication, role routing, finance, orders/contracts, visits,
  preferences and reporting on those profiles.
- `tests/browser/responsive.spec.ts` additionally sweeps **320, 360, 375, 390, 414, 430, 768, 1024 and 1280 px**
  across admin routes, asserting no horizontal document overflow, no error alerts, drawer open/close/Escape with
  focus restoration, reserved bottom-bar space, and dialog fit, 16 px inputs and visible actions at 320/360/430 px.
- Screenshots were captured at 320, 360 and 430 px in `tests/.artifacts/` during the sweep. These are Chromium
  renders, not physical-device screenshots.

**Not verified here:** physical iPhone/iPad or Android hardware, iOS Safari/WebKit, Android Chrome or Android
WebView, real camera/GPS permissions, PWA installation prompts, service-worker updates on a live CDN, push
notifications, background location, or screen-reader behaviour on a phone. Hosted HTTPS, Supabase Auth/Storage
configuration and deployment caching were not exercised. `localhost` is treated as a secure context; an HTTP LAN
address is not.

## Native packaging (APK / IPA)

- There is **no** Capacitor, Cordova, React Native or Expo project in this repository, and no Android or iOS
  native project. No APK or IPA has been built, signed or tested.
- The current deliverable is a **browser PWA**. On a supported browser, users can install it from the browser
  menu ("Add to Home Screen" on iOS). Installation prompts are browser/OS-controlled and are not guaranteed.
- If a store-distributed APK is required later, the usual approach is a Capacitor shell around the hosted PWA.
  That requires Android Studio/SDK and signing keys, WebView camera and file-provider permissions, an offline
  strategy, and testing on physical devices. None of that exists yet; it should not be reported as delivered.

## Deployment prerequisites for the PWA

1. Serve the production build over HTTPS (or `localhost`); service workers and installation are unavailable on
   plain HTTP origins.
2. Keep `/manifest.webmanifest`, `/sw.js` and `/assets/icon-*.png` at the site root and served with correct MIME
   types. Do not cache `sw.js` aggressively, or updates will stall.
3. Allow same-origin service-worker registration in any Content-Security-Policy. No third-party worker or CDN is
   required.
4. Camera capture, GPS and installability depend on browser permissions; geolocation is only captured on explicit
   user action while the tab is open. Background tracking is described separately in `docs/MOBILE_API.md`.
