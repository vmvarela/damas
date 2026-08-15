# Damas web client

Dependency-free checkers UI, served by the `damas` binary itself (no
python http.server needed):

1. Start everything: `./zig-out/bin/damas web` (default port 8080, from
   `DZ_WS_PORT` if set). It prints the URL and opens the browser automatically
   (set `DZ_NO_BROWSER=1` to skip that).
2. Play at `http://127.0.0.1:8080` — the page, styles, script, and the
   WebSocket server all come from the one binary (use `?port=8081` in the URL
   if the WebSocket server is on a different port).

## Instalar como app (PWA)

El bundle estático (`zig build web` → `zig-out/web/`) es una PWA instalable.
En Chrome Android, abre la URL de GitHub Pages, menú ⋮ → **"Añadir a pantalla
de inicio"**. Offline vía service worker (cache-first).

En iPhone/iPad, abre la URL de GitHub Pages en Safari, toca Compartir → **"Añadir a pantalla de inicio"**. La app funciona offline (motor wasm + service worker); el botón LLM queda deshabilitado en modo offline.
