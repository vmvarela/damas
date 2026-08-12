# Damas Z web client

Dependency-free checkers UI.

1. Start the server: `DZ_WS_PORT=8080 ./zig-out/bin/damas-ws`
2. Serve this folder: `cd apps/web && python3 -m http.server 8099`
3. Open `http://127.0.0.1:8099/index.html` (use `?port=8081` if the WebSocket server is on a different port).
