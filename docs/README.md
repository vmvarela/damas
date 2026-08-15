# damas documentation

`damas` is a checkers engine and app family written in Zig 0.16. One shared
core serves four entry points: a config-driven match CLI, a terminal UI, a web
server with an embedded frontend, and a standalone WASM bundle that becomes a
PWA (Android TWA / iOS PWA). An LLM can play as a player. This documentation
explains the design, the engine internals, the LLM integration, and how to
build apps on top of the shared core.

## Table of contents

| Doc | Topic |
|-----|-------|
| [01-overview](01-overview.md) | What damas is: one core, four entry points, two rule variants |
| [02-architecture](02-architecture.md) | Layered architecture, module map, key design decisions |
| [03-engine](03-engine.md) | Engine internals: negamax, transposition table, zobrist hashing, timer |
| [04-llm-integration](04-llm-integration.md) | LLM player: provider interface, factory, OpenAI/Ollama, validation loop |
| [05-tui](05-tui.md) | Terminal UI built on libvaxis |
| [06-web-server](06-web-server.md) | Embedded web server: assets, WebSocket game protocol, browser launch |
| [07-web-wasm](07-web-wasm.md) | Standalone WASM build and the browser client |
| [08-android-twa](08-android-twa.md) | Android app via Trusted Web Activity |
| [09-ios-pwa](09-ios-pwa.md) | iOS app via PWA |
| [10-build-ci-packaging](10-build-ci-packaging.md) | Build system, CI workflows, release packaging |

Docs 03–10 are written in later phases. The links above are the final
destinations; they resolve once those documents land.

## Learning path

Pick a path based on what you want to learn. Each path is a reading order, not
a strict requirement.

**Learn Zig from this repo** — small modules, std-only core, clear boundaries.

1. [01-overview](01-overview.md) — what the project is
2. [02-architecture](02-architecture.md) — how the layers fit
3. [03-engine](03-engine.md) — read `src/core/*` and `src/core/engine/*` (the smallest, purest Zig in the repo)
4. [05-tui](05-tui.md) — a real dependency-using program (libvaxis)

**Understand the engine** — rules, move generation, search.

1. [01-overview](01-overview.md) — the two rule variants
2. [02-architecture](02-architecture.md) — where the engine sits
3. [03-engine](03-engine.md) — negamax + transposition table + zobrist + timer
4. [04-llm-integration](04-llm-integration.md) — the engine's non-engine opponent

**Build apps on a shared core** — the architecture that makes four entry
points cheap.

1. [02-architecture](02-architecture.md) — the core/runtime split and design decisions
2. [06-web-server](06-web-server.md) — the embedded server + protocol
3. [07-web-wasm](07-web-wasm.md) — the WASM ABI reusing the same protocol
4. [08-android-twa](08-android-twa.md) and [09-ios-pwa](09-ios-pwa.md) — mobile packaging

**Add an LLM provider** — extend the player roster.

1. [04-llm-integration](04-llm-integration.md) — provider interface, factory, validation
2. [02-architecture](02-architecture.md) — where the LLM layer plugs in
3. [10-build-ci-packaging](10-build-ci-packaging.md) — testing the new provider

## Conventions

Every document follows the same arc, so you always know where to look:

- **What** — one paragraph: what this document covers and the one-sentence answer.
- **Why** — the decisions and constraints that shaped the design.
- **How** — the explanation, always with at least one Mermaid diagram in a
  ` ```mermaid ` block.
- **Code tour** — the claims mapped to real code. Every `file:line` reference
  is verified against the current source. No invented APIs.
- **Drifting references** — `file:line` refs into `src/` are stable, but refs
  into `.github/workflows/*`, `packaging/*` and `build.zig` shift with every
  CI/package/build edit: re-verify them whenever those files change.
- **Try it** — real commands you can run to reproduce the behavior.
- **Further reading** — relative links to related documents.

Code identifiers use backticks. Language is English, sentences are short.
