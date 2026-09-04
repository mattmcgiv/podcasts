# DEPRECATED — 1 October 2026

The Pods **iPhone app is deprecated as of 1 October 2026**. Do not review,
read, or append to this tree for feature work. The source is kept until
removal; it is not a place to continue development.

## What this covers

| Area | Location |
|------|----------|
| iPhone client app (Swift) | `ios/Pods/` (`PodsApp`, `PodsWebView`, playback, cast, UI shell) |
| iPhone "backend" | `ios/Pods/PodsLocalServer.swift`, `PodsRustBackend.swift`, `PodsHTTP.swift`, and the rest of the in-app loopback shell |
| Signing / installing | `ios/*.sh` refresh/install/signing helpers, `ios/dev.mcgiv.pods.refresh.plist.template`, `ios/Pods.xcodeproj` |
| iPhone FFI / staticlib build | `backend/src/ffi.rs`, `backend/include/pods_backend.h`, `backend/build-ios.sh` |

The shared Rust library/API in `backend/` (except the iPhone FFI and
`build-ios.sh`) is **not** deprecated. Neither is `client/`, `mac/`, or
`shared/`.

## Rules for later work

1. Do not add features, refactors, or tests that extend this code.
2. Do not treat `ios/` as the default app/runtime. See `AGENTS.md`.
3. Touch this tree only for security fixes or for the eventual deletion.
4. The dated markers (`@available(*, deprecated)`, `#warning`, script
   stderr warnings, and file banners) are intentional. Do not remove them
   to "clean up" warnings.
