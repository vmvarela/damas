# damas

Checkers engine and apps. Core + C library are zero-dependency std-only Zig;
the TUI uses [libvaxis](https://github.com/rockorager/libvaxis) (Zig 0.16).
Two rule variants: **English draughts** (default) and **Spanish damas** (flying
kings, pawns capture forward only, mandatory capture with the quantity/quality
laws).

One binary, four entry points:

- `damas` — config-driven match (`config.json`: human | minimax | llm;
  `"rules": "english" | "spanish"` selects the variant, default spanish)
- `damas web` — web UI + WebSocket server on `http://127.0.0.1:8080`
  (port from `DZ_WS_PORT`; `DZ_NO_BROWSER=1` skips opening the browser;
  rule variant selectable in the UI, sent with each new game)
- `damas tui` — full-screen terminal UI (uses the `rules` from config.json)
- `damas help` / `damas --version` — usage / version stamp

`--rules english|spanish` overrides the variant on any entry point (before or
after the subcommand, e.g. `damas --rules spanish` or `damas tui --rules
spanish`): it beats `config.json` in the match CLI and TUI, and sets the
server's default variant for the web UI.

## Documentation

Learn the design, engine and LLM integration: [docs/](docs/README.md).

Build: `zig build` (binaries in `zig-out/bin/`), tests: `zig build test`
(requires Zig **0.16.0 release** — dev builds don't compile libvaxis).

## LLM providers

LLM players (`"type": "llm"` in `config.json`) use an OpenAI-compatible chat
endpoint. Set the provider's API key env var; `ollama` needs no key (local
`http://localhost:11434`). Example:

```json
{ "player_white": { "type": "llm", "provider": "groq", "model": "llama-3.3-70b-versatile" } }
```

Omitting `provider` (or passing `--provider`) auto-detects: the first
`*_API_KEY` env var set (table order) wins; a set-but-empty var
(`GROQ_API_KEY=""`) is ignored. `--provider <name>` beats `config.json` and
applies to `damas`, `damas tui`, and `damas web`.

| provider   | API key env var      |
|------------|----------------------|
| groq       | GROQ_API_KEY         |
| openai     | OPENAI_API_KEY       |
| deepseek   | DEEPSEEK_API_KEY     |
| mistral    | MISTRAL_API_KEY      |
| together   | TOGETHER_API_KEY     |
| fireworks  | FIREWORKS_API_KEY    |
| xai        | XAI_API_KEY          |
| cerebras   | CEREBRAS_API_KEY     |
| openrouter | OPENROUTER_API_KEY   |
| perplexity | PERPLEXITY_API_KEY   |
| sambanova  | SAMBANOVA_API_KEY    |
| deepinfra  | DEEPINFRA_API_KEY    |
| github     | GITHUB_TOKEN         |
| ollama     | (no key, local)      |

## Web: native server or standalone WASM

Two ways to run the web UI:

- **Embedded server** (default): `damas web` serves the UI + WebSocket on the
  loopback port. LLM play works (provider from `config.json` / env keys).
- **Static/WASM**: `zig build web` produces `zig-out/web/` — `damas.wasm` plus
  the eight web assets (page, styles, script, manifest, service worker,
  icons) — which deploys to any static host (GitHub Pages, nginx,
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
push to master/main (enable it: repo **Settings → Pages → Source: GitHub
Actions**).

## Install as an app (PWA)

The WASM bundle is an installable PWA (manifest + service worker). On Chrome
Android, open the GitHub Pages URL (e.g. `https://vmvarela.github.io/damas/`),
open the ⋮ menu and pick **"Add to Home screen"**; once installed, the app
works offline thanks to the service worker (cache-first). iOS Safari: Share →
"Add to Home Screen" (see [docs/09-ios-pwa.md](docs/09-ios-pwa.md)).

## Development

```sh
zig build            # build the native binary
zig build test       # unit + integration tests
zig build web        # WASM bundle → zig-out/web/
zig build -Dversion=0.1.0   # stamp the version
```
