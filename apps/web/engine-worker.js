// engine-worker.js — owns the damas.wasm instance off the main thread so
// engine turns (compute_minimax) never block UI rendering.
//
// Message protocol (no correlation ids: the app guarantees at most one
// in-flight request via its busy flag, so every response/error maps to the
// single request posted before it):
//   main -> worker  {type:'init', rules}      worker -> main {type:'ready'}
//                                             worker -> main {type:'error', message}
//   main -> worker  {type:'request', payload} worker -> main {type:'response', msg}
//                                             worker -> main {type:'error', message}
let wasm = null;

self.onmessage = (ev) => {
  const { type } = ev.data;
  if (type === 'init') init(ev.data.rules);
  else if (type === 'request') handleRequest(ev.data.payload);
};

async function init(rules) {
  try {
    const imports = { env: { dz_now_ms: () => performance.now() } };
    let mod;
    try {
      mod = await WebAssembly.instantiateStreaming(fetch('damas.wasm'), imports);
    } catch (e) {
      // Some static servers serve .wasm with the wrong MIME type — fall back.
      const buf = await (await fetch('damas.wasm')).arrayBuffer();
      mod = await WebAssembly.instantiate(buf, imports);
    }
    wasm = mod.instance.exports;
    // Variant enum: english = 0, spanish = 1.
    wasm.dz_init(rules === 'spanish' ? 1 : 0);
    postMessage({ type: 'ready' });
  } catch (e) {
    postMessage({ type: 'error', message: e.message });
  }
}

// Same wire logic as the WebSocket server: one JSON request in, one JSON
// state out. ABI: dz_req_ptr()/dz_req_cap() expose a request buffer,
// dz_handle(len) returns the response JSON packed as ptr<<32|len, valid
// until the next call.
function handleRequest(payload) {
  if (!wasm) {
    postMessage({ type: 'error', message: 'Engine not loaded. Refresh.' });
    return;
  }
  // Atomic w.r.t. the message queue: dz_handle is synchronous, so the next
  // request only runs after this one fully returns — no worker-side guard needed.
  const json = JSON.stringify(payload);
  const bytes = new TextEncoder().encode(json);
  if (bytes.length > wasm.dz_req_cap()) {
    postMessage({ type: 'error', message: 'Request too large for WASM buffer' });
    return;
  }
  const ptr = wasm.dz_req_ptr();
  new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
  const packed = wasm.dz_handle(bytes.length);
  if (packed === 0n) {
    // dz_handle returns 0 on buffer overflow or allocation failure; the
    // game may have advanced before the OOM, so this is honest either way.
    postMessage({ type: 'error', message: 'Engine error (memoria)' });
    return;
  }
  const respPtr = Number((packed >> 32n) & 0xffffffffn);
  const respLen = Number(packed & 0xffffffffn);
  try {
    const msg = JSON.parse(
      new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, respPtr, respLen))
    );
    postMessage({ type: 'response', msg });
  } catch (e) {
    postMessage({ type: 'error', message: 'Malformed WASM response' });
  }
}
