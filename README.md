# damas-z

Checkers (English draughts) engine and apps — zero dependencies, std only.

One binary, three entry points:

- `damas-z` — config-driven match (`config.json`: human | minimax | llm)
- `damas-z web` — web UI + WebSocket server on `http://127.0.0.1:8080`
  (port from `DZ_WS_PORT`; `DZ_NO_BROWSER=1` skips opening the browser)
- `damas-z tui` — full-screen terminal UI
- `damas-z help` — usage

Build: `zig build` (binaries in `zig-out/bin/`), tests: `zig build test`.
The `libdamas` static library (`src/c_api.zig` + `include/damas.h`)
cross-compiles to any target (`-Dtarget=aarch64-linux`, `-Dtarget=wasm32-wasi`).
