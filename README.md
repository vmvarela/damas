# damas

Checkers engine and apps. Core + C library are zero-dependency std-only Zig;
the TUI uses [libvaxis](https://github.com/rockorager/libvaxis) (Zig 0.16).
Two rule variants: **English draughts** (default) and **Spanish damas** (flying
kings, pawns capture forward only, mandatory capture with the quantity/quality
laws).

One binary, four entry points:

- `damas` — config-driven match (`config.json`: human | minimax | llm;
  `"rules": "english" | "spanish"` selects the variant, default english)
- `damas web` — web UI + WebSocket server on `http://127.0.0.1:8080`
  (port from `DZ_WS_PORT`; `DZ_NO_BROWSER=1` skips opening the browser;
  rule variant selectable in the UI, sent with each new game)
- `damas tui` — full-screen terminal UI (uses the `rules` from config.json)
- `damas help` / `damas --version` — usage / version stamp

`--rules english|spanish` overrides the variant on any entry point (before or
after the subcommand, e.g. `damas --rules spanish` or `damas tui --rules
spanish`): it beats `config.json` in the match CLI and TUI, and sets the
server's default variant for the web UI.

Build: `zig build` (binaries in `zig-out/bin/`), tests: `zig build test`
(requires Zig **0.16.0 release** — dev builds don't compile libvaxis).
The `libdamas` static library (`src/c_api.zig` + `include/damas.h`)
cross-compiles to any target (`-Dtarget=aarch64-linux`, `-Dtarget=wasm32-wasi`);
`dz_game_new_with_rules(0|1)` selects the variant (see `DZ_RULES_*` in the header).

## Web: native server or standalone WASM

Two ways to run the web UI:

- **Embedded server** (default): `damas web` serves the UI + WebSocket on the
  loopback port. LLM play works (provider from `config.json` / env keys).
- **Static/WASM**: `zig build web` produces `zig-out/web/` — `damas.wasm` plus
  the three assets — which deploys to any static host (GitHub Pages, nginx,
  `python3 -m http.server`). The page auto-detects the mode (HEAD probe on
  `damas.wasm`); `?server` / `?wasm` force a mode. In WASM mode the engine
  runs fully in-browser with **no backend**, and LLM play is disabled (no API
  keys in static hosting).

## Distribution

CI (`.github/workflows/ci.yml`) builds and smoke-tests on Ubuntu, macOS and
Windows (pin `0.16.0`). `.github/workflows/build-all.yml` cross-compiles the
14 release targets on every PR.

Tag `v*.*.*` triggers `.github/workflows/release.yml`:
binaries for Linux (musl), macOS, Windows, FreeBSD and NetBSD; a
`damas-web.zip` WASM bundle; `sha256sums.txt`; and — once the corresponding
secrets/repos are configured — npm (`@vmvarela/damas`), the Homebrew tap, AUR,
deb/rpm/apk via nfpm, WinGet, Scoop, Nix, and apt/rpm/apk repository
dispatches.

`.github/workflows/pages.yml` deploys the WASM bundle to GitHub Pages on every
push to master (enable it: repo **Settings → Pages → Source: GitHub Actions**).

## Development

```sh
zig build            # build the native binary
zig build test       # unit + integration tests
zig build web        # WASM bundle → zig-out/web/
zig build -Dversion=0.1.0   # stamp the version
```
