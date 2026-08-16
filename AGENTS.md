# AGENTS.md

- Use Zig 0.16.0 for all backend and core code, except in environments where Zig is not applicable (e.g., web frontends or mobile/desktop apps built with other toolchains).
- Write the test before implementing a feature. Tests come first.
- Run the full test suite before every commit, and ensure all tests pass. Do not commit with failing tests.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages.
- Write all documentation and code comments in English.

## Known issue: macOS `zig build` — "unable to find libSystem system library"

Recurring on this machine. Zig's SDK detection on macOS uses a fake `xcrun`
shim: `/tmp/zr_fake_xcrun/xcrun` (on `PATH`) answers `--show-sdk-path` with
`/tmp/zr_macos_sdk_wrapper` and forwards everything else to the real
`/usr/bin/xcrun`. If that wrapper is missing or its symlinks are broken
(e.g. after `/tmp` cleanup, or a dangling `usr/lib/libSystem.B.tbd`), any
build that needs to link fails with:

```
error: unable to find libSystem system library
    note: tried /tmp/zr_macos_sdk_wrapper/usr/lib/libSystem.tbd
```

Note: cached builds can still succeed with a broken wrapper; it only fails on
a forced re-link (source change), which makes it look like the code broke the
build. Fix — recreate the wrapper (Zig does not regenerate it):

```sh
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
mkdir -p /tmp/zr_macos_sdk_wrapper/usr/lib
ln -sfn "$SDK/usr/lib/libSystem.tbd"      /tmp/zr_macos_sdk_wrapper/usr/lib/libSystem.tbd
ln -sfn "$SDK/usr/lib/libSystem.B.tbd"    /tmp/zr_macos_sdk_wrapper/usr/lib/libSystem.B.tbd
ln -sfn "$SDK/System/Library/Frameworks"  /tmp/zr_macos_sdk_wrapper/System
```

Verify with `xcrun --show-sdk-path` → should print
`/tmp/zr_macos_sdk_wrapper`. See memory obs. 1172 in Engram for the original
diagnosis.
