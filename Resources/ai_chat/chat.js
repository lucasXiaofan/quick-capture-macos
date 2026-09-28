// Chat page logic. Swift sends events through qc.receive(); the page replies with post().
(() => {
  const $ = id => document.getElementById(id);
  const log = $('log'), input = $('input'), modelSelect = $('model');
  const post = msg => window.webkit?.messageHandlers?.qc?.postMessage(msg);
  const render = QCRender.createRenderer({
    marked, katex,
    // Allow file links like "src/app.swift:42" (DOMPurify would read "app.swift:" as an unknown scheme);
    // only script-capable schemes are refused.
    sanitize: html => DOMPurify.sanitize(html, { ADD_ATTR: ['target'], ALLOWED_URI_REGEXP: /^(?!\s*(?:javascript|vbscript|data)\s*:)/i }),
  });
  const escapeHtml = QCRender.escapeHtml;

  let state = { models: [], model: '', directory: '', busy: false };
  let turn = null;          // The assistant reply being streamed.
  let breakText = false;    // Next text delta starts a new text part.

  // ---------- Rendering helpers ----------

  function nearBottom() { return log.scrollHeight - log.scrollTop - log.clientHeight < 80; }
  function stick(wasNear) { if (wasNear) log.scrollTop = log.scrollHeight; }

  function hideEmpty() { $('empty')?.remove(); }

  function modelLabel() {
    return state.models.find(m => m.key === state.model)?.label || 'the model';
  }

  function updateEmpty() {
    const detail = $('empty-detail');
    if (!detail) return;
    if (state.missing) detail.textContent = state.missing;
    else if (state.detecting && !state.models.length) detail.textContent = 'Looking for Claude Code and Codex…';
    else detail.textContent = `${modelLabel()} · working in ${state.directoryLabel || '~'}. It can search the web`
      + (state.permissions === 'read_only' ? ' and read files here.' : ' and read and edit files here.');
  }

  function decorate(el) {
    el.querySelectorAll('pre code').forEach(code => {
      if (window.hljs && !code.dataset.hl) { try { hljs.highlightElement(code); } catch (e) {} code.dataset.hl = '1'; }
      const pre = code.parentElement;
      if (!pre.querySelector('.copy')) {
        const b = document.createElement('button');
        b.className = 'copy'; b.textContent = 'Copy';
        b.onclick = e => { e.stopPropagation(); post({ type: 'copy', text: code.innerText }); flash(b); };
        pre.appendChild(b);
      }
    });
    el.querySelectorAll('a[href]').forEach(a => { a.title = a.getAttribute('href'); });
  }

  function flash(button) {
    const old = button.textContent;
    button.textContent = 'Copied';
    setTimeout(() => { button.textContent = old; }, 1000);
  }

  let pendingParts = new Set(), frame = 0;
  function scheduleRender(part) {
    pendingParts.add(part);
    if (!frame) frame = requestAnimationFrame(flushRender);
  }
  function flushRender() {
    frame = 0;
    const near = nearBottom();
    for (const part of pendingParts) { part.el.innerHTML = render(part.text); decorate(part.el); }
    pendingParts.clear();
    stick(near);
  }

  // ---------- Transcript ----------

  function addUser(text) {
    hideEmpty();
    const row = document.createElement('div');
    row.className = 'msg user';
    row.innerHTML = `<div class="bubble">${escapeHtml(text)}</div>`;
    log.appendChild(row);
    log.scrollTop = log.scrollHeight;
  }

  function startTurn() {
    hideEmpty();
    const el = document.createElement('div');
    el.className = 'msg assistant';
    el.innerHTML = '<div class="parts"></div><div class="status"><span class="dots"><span></span><span></span><span></span></span><span class="text">Thinking…</span></div><div class="meta"></div>';
    log.appendChild(el);
    turn = { el, parts: [], tools: {}, model: modelLabel(), started: Date.now() };
    breakText = false;
    log.scrollTop = log.scrollHeight;
  }

  function ensureTurn() { if (!turn) startTurn(); return turn; }

  function textPart(initial = '') {
    const t = ensureTurn();
    const el = document.createElement('div');
    el.className = 'md';
    t.el.querySelector('.parts').appendChild(el);
    const part = { kind: 'text', text: initial, el };
    t.parts.push(part);
    breakText = false;
    return part;
  }

  function lastTextPart() {
    const t = ensureTurn();
    const last = t.parts[t.parts.length - 1];
    return !breakText && last?.kind === 'text' ? last : textPart();
  }

  function setStatus(text) {
    const s = ensureTurn().el.querySelector('.status');
    if (s) { s.style.display = ''; s.querySelector('.text').textContent = text; }
  }

  function upsertTool(ev) {
    const t = ensureTurn();
    let tool = t.tools[ev.id];
    if (!tool) {
      const el = document.createElement('details');
      el.className = 'tool running';
      el.innerHTML = '<summary><span class="state"></span><span class="name"></span><span class="detail"></span></summary><pre hidden></pre>';
      t.el.querySelector('.parts').appendChild(el);
      tool = t.tools[ev.id] = { el };
      t.parts.push({ kind: 'tool', el });
      breakText = true;
    }
    tool.el.querySelector('.name').textContent = ev.name;
    const detail = tool.el.querySelector('.detail');
    const shown = relative(ev.detail || '');
    if (ev.path) {
      detail.innerHTML = `<a href="${escapeHtml(ev.path)}">${escapeHtml(shown)}</a>`;
    } else {
      detail.textContent = shown;
    }
    detail.title = ev.detail || '';
    setStatus(`${ev.name}…`);
  }

  function toolDone(ev) {
    const tool = turn?.tools[ev.id];
    if (!tool) return;
    tool.el.classList.remove('running');
    tool.el.classList.add(ev.ok ? 'ok' : 'failed');
    const pre = tool.el.querySelector('pre');
    if (ev.output && ev.output.trim()) { pre.textContent = ev.output; pre.hidden = false; }
    setStatus('Thinking…');
  }

  function relative(path) {
    const dir = state.directory.endsWith('/') ? state.directory : state.directory + '/';
    return path.startsWith(dir) ? path.slice(dir.length) : path;
  }

  function addError(message) {
    const t = ensureTurn();
    const el = document.createElement('div');
    el.className = 'error';
    el.textContent = message;
    t.el.querySelector('.parts').appendChild(el);
    t.parts.push({ kind: 'error', el });
    breakText = true;
  }

  function finishTurn(ev) {
    if (!turn) return;
    flushRender();
    turn.el.querySelector('.status')?.remove();
    turn.el.querySelectorAll('details.tool.running').forEach(d => {
      d.classList.remove('running'); d.classList.add(ev.stopped ? 'failed' : 'ok');
    });
    const seconds = ev.seconds ?? (Date.now() - turn.started) / 1000;
    const bits = [turn.model, `${seconds.toFixed(1)}s`];
    if (typeof ev.cost === 'number') bits.push(`$${ev.cost.toFixed(ev.cost < 0.1 ? 3 : 2)}`);
    if (ev.stopped) bits.push('stopped');
    const meta = turn.el.querySelector('.meta');
    meta.textContent = bits.join(' · ');
    const text = turn.parts.filter(p => p.kind === 'text').map(p => p.text).join('\n\n').trim();
    if (text) {
      const b = document.createElement('button');
      b.textContent = 'Copy';
      b.onclick = () => { post({ type: 'copy', text }); flash(b); };
      meta.appendChild(b);
    }
    turn = null;
  }

  function addNotice(text) {
    hideEmpty();
    const el = document.createElement('div');
    el.className = 'notice';
    el.textContent = text;
    log.appendChild(el);
  }

  function reset(notice) {
    turn = null;
    log.innerHTML = '<div id="empty"><h1>Ask anything</h1><p id="empty-detail"></p></div>';
    updateEmpty();
    if (notice) {
      const p = document.createElement('p');
      p.className = 'notice'; p.textContent = notice;
      $('empty').appendChild(p);
    }
  }

  // ---------- State ----------

  function applyState(s) {
    state = { ...state, ...s };
    const groups = {};
    for (const m of state.models) (groups[m.provider] ||= []).push(m);
    modelSelect.innerHTML = Object.entries(groups).map(([provider, models]) =>
      `<optgroup label="${escapeHtml(provider)}">` +
      models.map(m => `<option value="${escapeHtml(m.key)}">${escapeHtml(m.label)}</option>`).join('') +
      '</optgroup>').join('') || '<option>No AI CLI found</option>';
    modelSelect.value = state.model;
    modelSelect.disabled = !state.models.length;
    $('folder-name').textContent = state.directoryLabel || '~';
    $('folder').title = `Working folder: ${state.directory}\nClick to change`;
    $('permissions').textContent = { read_only: 'read only', edit: 'can edit files', full: 'full access' }[state.permissions] || '';
    setBusy(state.busy);
    updateEmpty();
  }

  function setBusy(busy) {
    state.busy = busy;
    document.body.classList.toggle('busy', busy);
    $('send').title = busy ? 'Stop (⌘.)' : 'Send (↩)';
    updateSend();
  }

  function updateSend() {
    $('send').disabled = !state.busy && (!input.value.trim() || !state.models.length);
  }

  // ---------- Events from Swift ----------

  window.qc = {
    receive(ev) {
      const near = nearBottom();
      switch (ev.type) {
        case 'state': applyState(ev); break;
        case 'focus': input.focus(); break;
        case 'reset': reset(ev.notice); break;
        case 'insert': insertText(ev.text); break;
        case 'status': setStatus(ev.text); break;
        case 'text_break': breakText = true; break;
        case 'text_delta': { const p = lastTextPart(); p.text += ev.text; scheduleRender(p); setStatus('Writing…'); break; }
        case 'text': { const p = textPart(ev.text); scheduleRender(p); breakText = true; break; }
        case 'tool': upsertTool(ev); break;
        case 'tool_done': toolDone(ev); break;
        case 'notice': setStatus(ev.text); break;
        case 'error': addError(ev.message); break;
        case 'done': finishTurn(ev); break;
        case 'idle': if (turn) finishTurn({}); setBusy(false); break;
      }
      stick(near);
    },
  };

  // ---------- Input ----------

  function submit() {
    if (state.busy) { post({ type: 'stop' }); return; }
    const text = input.value.trim();
    if (!text || !state.models.length) return;
    addUser(text);
    startTurn();
    setBusy(true);
    post({ type: 'send', text });
    input.value = '';
    autosize();
  }

  function insertText(text) {
    const start = input.selectionStart ?? input.value.length, end = input.selectionEnd ?? start;
    const before = input.value.slice(0, start), after = input.value.slice(end);
    const pad = before && !/\s$/.test(before) ? ' ' : '';
    input.value = before + pad + text + ' ' + after;
    input.focus();
    autosize();
  }

  function autosize() {
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, window.innerHeight * 0.4) + 'px';
    updateSend();
  }

  $('composer').addEventListener('submit', e => { e.preventDefault(); submit(); });
  input.addEventListener('input', autosize);
  input.addEventListener('keydown', e => {
    // Enter sends, unless an input method (e.g. Chinese/Japanese) is composing.
    if (e.key === 'Enter' && !e.shiftKey && !e.altKey && !e.isComposing && e.keyCode !== 229) {
      e.preventDefault();
      submit();
    }
  });
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && !e.isComposing) { e.preventDefault(); post({ type: 'hide' }); }
    else if (e.metaKey && e.key === '.') { e.preventDefault(); post({ type: 'stop' }); }
    else if (e.metaKey && (e.key === 'n' || e.key === 'N')) { e.preventDefault(); post({ type: 'new_chat' }); }
    else if (e.metaKey && e.key === 'l') { e.preventDefault(); input.focus(); }
  });
  modelSelect.addEventListener('change', () => post({ type: 'set_model', key: modelSelect.value }));
  $('folder').addEventListener('click', () => post({ type: 'choose_folder' }));
  $('new-chat').addEventListener('click', () => post({ type: 'new_chat' }));

  // Every link opens outside the page: web links in the browser, file links in their app (⌥-click reveals in Finder).
  document.addEventListener('click', e => {
    const a = e.target.closest?.('a[href]');
    if (!a) return;
    e.preventDefault();
    post({ type: 'open', href: a.getAttribute('href'), reveal: e.altKey });
  });

  autosize();
  post({ type: 'ready' });
})();
