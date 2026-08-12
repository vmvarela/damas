(() => {
  'use strict';

  const DEFAULT_PORT = 8080;
  const wsUrl = () => {
    const params = new URLSearchParams(location.search);
    const port = params.get('port') || params.get('p') || DEFAULT_PORT;
    return `ws://127.0.0.1:${port}`;
  };

  const boardEl = document.getElementById('board');
  const turnEl = document.getElementById('turn');
  const winnerEl = document.getElementById('winner');
  const statusEl = document.getElementById('status');
  const historyEl = document.getElementById('history');
  const busyEl = document.getElementById('busy');
  const dotEl = document.getElementById('dot');
  const connLabelEl = document.getElementById('conn-label');
  const connEl = document.getElementById('connection');

  const btnNew = document.getElementById('btn-new');
  const btnEngine = document.getElementById('btn-engine');
  const btnLlm = document.getElementById('btn-llm');
  const modelInput = document.getElementById('model');
  const autoToggle = document.getElementById('auto');

  let ws = null;
  let reconnectTimer = null;
  let selectedSq = null;
  let busy = false;
  let state = null;
  let moveHistory = [];
  let lastAction = null;

  // Square index mapping, verified against src/core/board.zig:
  // - Dark squares satisfy (row + col) is even.
  // - For a dark square, idx = row * 4 + floor(col / 2).
  // - Inverse: row = floor(idx / 4), col = (idx % 4) * 2 + (row % 2).
  function sqToRowCol(sq) {
    const row = Math.floor(sq / 4);
    const col = (sq % 4) * 2 + (row % 2);
    return { row, col };
  }

  function rowColToSq(row, col) {
    return row * 4 + Math.floor(col / 2);
  }

  function isDark(row, col) {
    return ((row + col) % 2) === 0;
  }

  function setConnection(status, label) {
    connEl.className = 'connection ' + status;
    connLabelEl.textContent = label;
  }

  function setStatus(text, isError = false) {
    statusEl.textContent = text;
    statusEl.classList.toggle('error', isError);
  }

  function setBusy(v) {
    busy = v;
    busyEl.hidden = !v;
    boardEl.setAttribute('aria-busy', v ? 'true' : 'false');
    btnEngine.disabled = v;
    btnLlm.disabled = v;
    btnNew.disabled = v;
  }

  function connect() {
    if (ws) return;
    setConnection('connecting', 'connecting…');
    try {
      ws = new WebSocket(wsUrl());
    } catch (e) {
      setStatus('Cannot create WebSocket: ' + e.message, true);
      scheduleReconnect();
      return;
    }

    ws.addEventListener('open', () => {
      setConnection('connected', 'connected');
      moveHistory = [];
      selectedSq = null;
      setStatus('Reconnected — game reset.');
      send({ action: 'new_game' });
    });

    ws.addEventListener('message', (ev) => {
      let msg;
      try {
        msg = JSON.parse(ev.data);
      } catch (e) {
        setStatus('Malformed server message', true);
        return;
      }
      handleState(msg);
    });

    ws.addEventListener('close', () => {
      ws = null;
      lastAction = null;
      setConnection('', 'disconnected');
      setStatus('Connection lost. Reconnecting…', true);
      scheduleReconnect();
    });

    ws.addEventListener('error', () => {
      setStatus('WebSocket error', true);
    });
  }

  function scheduleReconnect() {
    if (reconnectTimer) return;
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, 1500);
  }

  function send(payload) {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      setBusy(false);
      lastAction = null;
      setStatus('Not connected. Wait or refresh.', true);
      return false;
    }
    ws.send(JSON.stringify(payload));
    return true;
  }

  function pieceClass(ch) {
    switch (ch) {
      case 'w': return ['piece', 'white'];
      case 'W': return ['piece', 'white', 'king'];
      case 'b': return ['piece', 'black'];
      case 'B': return ['piece', 'black', 'king'];
      default: return null;
    }
  }

  function pieceOwner(ch) {
    if (ch === 'w' || ch === 'W') return 'white';
    if (ch === 'b' || ch === 'B') return 'black';
    return null;
  }

  function renderBoard() {
    boardEl.innerHTML = '';
    if (!state || !state.board || state.board.length !== 64) {
      boardEl.textContent = 'No board state yet.';
      return;
    }

    const board = state.board;
    for (let row = 0; row < 8; row++) {
      for (let col = 0; col < 8; col++) {
        const cell = document.createElement('div');
        cell.className = 'cell ' + (isDark(row, col) ? 'dark' : 'light');
        cell.setAttribute('role', 'gridcell');
        cell.dataset.row = row;
        cell.dataset.col = col;

        if (isDark(row, col)) {
          cell.tabIndex = 0;
          const sq = rowColToSq(row, col);
          const ch = board[row * 8 + col];
          const classes = pieceClass(ch);

          const idxLabel = document.createElement('span');
          idxLabel.className = 'idx';
          idxLabel.textContent = sq;
          cell.appendChild(idxLabel);

          if (classes) {
            const piece = document.createElement('div');
            piece.className = classes.join(' ');
            piece.setAttribute('role', 'img');
            piece.setAttribute('aria-label', describePiece(ch));
            if (sq === selectedSq) piece.classList.add('selected');
            if (ch === 'W' || ch === 'B') piece.textContent = '♔';
            cell.appendChild(piece);
          }

          cell.addEventListener('click', () => onCellClick(row, col));
          cell.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              onCellClick(row, col);
            }
          });
        }

        boardEl.appendChild(cell);
      }
    }
  }

  function describePiece(ch) {
    if (ch === 'w') return 'white pawn';
    if (ch === 'W') return 'white king';
    if (ch === 'b') return 'black pawn';
    if (ch === 'B') return 'black king';
    return 'empty';
  }

  function onCellClick(row, col) {
    if (busy || !state || state.over) return;
    if (!isDark(row, col)) return;

    const sq = rowColToSq(row, col);
    const ch = state.board[row * 8 + col];
    const owner = pieceOwner(ch);

    if (selectedSq === null || (owner && owner === state.turn && selectedSq !== sq)) {
      if (owner && owner === state.turn) {
        selectedSq = sq;
        renderBoard();
        const rc = sqToRowCol(sq);
        setStatus(`Selected square ${sq} (${rc.row},${rc.col}). Click a target square.`);
      }
      return;
    }

    if (selectedSq === sq) {
      selectedSq = null;
      renderBoard();
      return;
    }

    // A piece is already selected; any other dark-square click becomes the target.
    const fromSq = selectedSq;
    selectedSq = null;
    renderBoard();
    setBusy(true);
    lastAction = 'make_move';
    send({ action: 'make_move', from: fromSq, to: sq });
  }

  function renderTurn() {
    if (!state) return;
    turnEl.textContent = state.turn;
    turnEl.className = 'turn-value ' + state.turn;
    if (state.over && state.winner) {
      winnerEl.hidden = false;
      winnerEl.textContent = `${state.winner} wins`;
    } else {
      winnerEl.hidden = true;
      winnerEl.textContent = '';
    }
  }

  function renderHistory() {
    historyEl.innerHTML = '';
    moveHistory.forEach((mv, i) => {
      const li = document.createElement('li');
      li.textContent = `${i + 1}. ${mv.turn}: ${fmtSq(mv.from)} → ${fmtSq(mv.to)}`;
      li.addEventListener('click', () => {
        selectedSq = null;
        highlightMove(mv);
      });
      historyEl.appendChild(li);
    });
    historyEl.scrollTop = historyEl.scrollHeight;
  }

  function fmtSq(sq) {
    const rc = sqToRowCol(sq);
    return `${rc.row},${rc.col}`;
  }

  function highlightMove(mv) {
    // Re-render so any previous highlights are cleared, then briefly mark the move squares.
    renderBoard();
    const cells = boardEl.querySelectorAll('.cell');
    cells.forEach((cell) => {
      const r = Number(cell.dataset.row);
      const c = Number(cell.dataset.col);
      if (!isDark(r, c)) return;
      const sq = rowColToSq(r, c);
      if (sq === mv.from || sq === mv.to) {
        cell.style.outline = '3px dashed var(--accent)';
      }
    });
    setTimeout(() => {
      cells.forEach((cell) => { cell.style.outline = ''; });
    }, 1200);
  }

  function handleState(msg) {
    setBusy(false);
    const wasHumanMove = lastAction === 'make_move';
    lastAction = null;

    if (msg.error) {
      setStatus(msg.error, true);
      return;
    }

    state = msg;

    if (msg.last_move && (msg.last_move.from !== undefined && msg.last_move.to !== undefined)) {
      const last = msg.last_move;
      const prev = moveHistory.length ? moveHistory[moveHistory.length - 1] : null;
      if (!prev || prev.from !== last.from || prev.to !== last.to) {
        moveHistory.push({
          turn: msg.turn === 'white' ? 'black' : 'white',
          from: last.from,
          to: last.to,
        });
      }
    }

    renderBoard();
    renderTurn();
    renderHistory();

    if (msg.over) {
      setStatus(msg.winner ? `Game over — ${msg.winner} wins.` : 'Game over — draw.');
      return;
    }

    setStatus(`${msg.turn} to move.`);

    // Auto-play opponent after a successful human move.
    if (wasHumanMove && autoToggle.checked && !state.over) {
      setBusy(true);
      lastAction = 'compute_minimax';
      send({ action: 'compute_minimax', time_limit_ms: 1000 });
    }
  }

  btnNew.addEventListener('click', () => {
    if (!state || busy) return;
    moveHistory = [];
    selectedSq = null;
    setBusy(true);
    send({ action: 'new_game' });
  });

  btnEngine.addEventListener('click', () => {
    if (!state || state.over || busy) return;
    setBusy(true);
    send({ action: 'compute_minimax', time_limit_ms: 1000 });
  });

  btnLlm.addEventListener('click', () => {
    if (!state || state.over || busy) return;
    const model = modelInput.value.trim();
    if (!model) {
      setStatus('Enter an LLM model name.', true);
      return;
    }
    setBusy(true);
    send({ action: 'request_llm', model });
  });

  // Number keys 1–9 select the 1st–9th piece of the side to move.
  document.addEventListener('keydown', (e) => {
    if (!state || state.over || busy) return;
    const num = Number(e.key);
    if (num < 1 || num > 9) return;
    const pieces = [];
    for (let sq = 0; sq < 32; sq++) {
      const rc = sqToRowCol(sq);
      const ch = state.board[rc.row * 8 + rc.col];
      if (pieceOwner(ch) === state.turn) pieces.push(sq);
    }
    if (pieces[num - 1] !== undefined) {
      selectedSq = pieces[num - 1];
      renderBoard();
      const rc = sqToRowCol(selectedSq);
      const cell = boardEl.querySelector(`.cell[data-row="${rc.row}"][data-col="${rc.col}"]`);
      if (cell) cell.focus();
    }
  });

  connect();
})();
