# damas

Checkers engine and apps — zero dependencies, std only. Two rule variants:
**English draughts** (default) and **Spanish damas** (flying kings, pawns
capture forward only, mandatory capture with the quantity/quality laws).

One binary, three entry points:

- `damas` — config-driven match (`config.json`: human | minimax | llm;
  `"rules": "english" | "spanish"` selects the variant, default english)
- `damas web` — web UI + WebSocket server on `http://127.0.0.1:8080`
  (port from `DZ_WS_PORT`; `DZ_NO_BROWSER=1` skips opening the browser;
  rule variant selectable in the UI, sent with each new game)
- `damas tui` — full-screen terminal UI (uses the `rules` from config.json)
- `damas help` — usage

`--rules english|spanish` overrides the variant on any entry point (before or
after the subcommand, e.g. `damas --rules spanish` or `damas tui --rules
spanish`): it beats `config.json` in the match CLI and TUI, and sets the
server's default variant for the web UI (`damas web --rules spanish` starts
every new game in Spanish until the selector is changed).

Build: `zig build` (binaries in `zig-out/bin/`), tests: `zig build test`.
The `libdamas` static library (`src/c_api.zig` + `include/damas.h`)
cross-compiles to any target (`-Dtarget=aarch64-linux`, `-Dtarget=wasm32-wasi`);
`dz_game_new_with_rules(0|1)` selects the variant (see `DZ_RULES_*` in the header).
