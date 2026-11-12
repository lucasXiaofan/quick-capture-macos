// The "new ticket" window. Page → Swift via webkit.messageHandlers.tk, Swift → page via TK.receive.
(function () {
  const L = TKLogic;
  const post = msg => { try { window.webkit.messageHandlers.tk.postMessage(msg); } catch (e) { /* not in the app */ } };
  const $ = id => document.getElementById(id);
  const text = $('text'), suggest = $('suggest'), stagedBox = $('staged'), hints = $('hints');
  const BOX = 'compose';
  let staged = [];          // [{ name, image }]
  let vocabulary = [];      // [{ tag, label, type }]
  let matches = [];
  let pick = { agent: '', model: '', effort: '' };
  let agents = [], defaultAgent = '';

  const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  /// mode: 'send' (agent classifies), 'append' (agent files it into an existing ticket), 'save' (no agent).
  function send(mode = 'send') {
    const value = text.value.trim();
    if (!value && !staged.length) return;
    post({ type: 'create', mode, text: value, staged: staged.map(s => s.name), ...(pick.agent ? { agent: pick.agent } : {}), ...(pick.model ? { model: pick.model } : {}), ...(pick.effort ? { effort: pick.effort } : {}) });
    pick = { agent: '', model: '', effort: '' };
    renderPick();
    text.value = '';
    staged = [];
    renderStaged();
    renderSuggest();
  }

  function renderStaged() {
    stagedBox.innerHTML = staged.map((s, i) => `
      <span class="chip file">${s.image ? `<img src="tkfile://s/${encodeURIComponent(s.name)}" alt="">` : '📎'}
        <span>${esc(s.name)}</span><button data-remove="${i}" title="Remove">×</button></span>`).join('');
  }

  function renderHints(state) {
    const kinds = state.structure.kinds.filter(k => k.id !== 'misc');
    const projects = state.structure.projects;
    const tags = [...new Set([...(state.structure.tags || []).filter(t => !/^LEGACY\b/.test(t.meaning || '')).map(t => t.id), ...state.tickets.flatMap(t => t.tags || [])])].filter(t => !L.internalTag(t));
    vocabulary = [
      ...kinds.map(k => ({ tag: k.id, label: k.icon + ' ' + k.label, type: 'kind' })),
      ...projects.map(p => ({ tag: p.id, label: p.name, type: 'project' })),
      ...tags.filter(t => !kinds.some(k => k.id === t) && !projects.some(p => p.id === t)).map(t => ({ tag: t, label: t, type: 'tag' })),
    ];
    // The projects touched most recently, then the kinds: the tags most likely to be wanted next.
    const recent = [];
    for (const t of state.tickets) if (t.project && !recent.includes(t.project)) recent.push(t.project);
    const quick = [...recent.slice(0, 3).map(id => vocabulary.find(v => v.tag === id)).filter(Boolean),
      ...vocabulary.filter(v => v.type === 'kind')];
    hints.innerHTML = quick.map(v => `<button class="hint ${v.type}" data-tag="${esc(v.tag)}" title="${esc(v.label)}">#${esc(v.tag)}</button>`).join('');
    agents = state.settings.agents || [];
    defaultAgent = state.settings.agentID;
    renderPick();
    $('compose-agent').textContent = state.settings.auto
      ? (state.settings.installed ? '' : state.settings.agent + ' is not installed')
      : 'saved without running the agent';
  }

  function renderPick() {
    const box = $('compose-pick');
    if (!agents.length) { box.innerHTML = ''; return; }
    const def = agents.find(a => a.id === defaultAgent) || agents[0];
    const current = agents.find(a => a.id === (pick.agent || defaultAgent)) || def;
    if (pick.effort && !current.efforts.includes(pick.effort)) pick.effort = '';
    if (pick.model && !current.models.some(m => m.id === pick.model)) pick.model = '';
    const label = id => (current.models.find(m => m.id === id) || { label: id }).label;
    box.innerHTML = `<select data-pick="agent" title="Which agent answers">
        <option value="">${esc(def.name)}</option>${agents.filter(a => a.id !== def.id).map(a => `<option value="${a.id}" ${pick.agent === a.id ? 'selected' : ''}>${esc(a.name)}</option>`).join('')}</select>
      <select data-pick="model" title="Model">
        <option value="">${current.model ? esc(label(current.model)) : 'default model'}</option>${current.models.filter(m => m.id !== current.model).map(m => `<option value="${esc(m.id)}" ${pick.model === m.id ? 'selected' : ''}>${esc(m.label)}</option>`).join('')}</select>
      <select data-pick="effort" title="Reasoning effort">
        <option value="">${current.effort ? esc(current.effort) : 'default effort'}</option>${current.efforts.filter(e => e !== current.effort).map(e => `<option ${pick.effort === e ? 'selected' : ''}>${e}</option>`).join('')}</select>`;
  }

  function renderSuggest() {
    const at = L.tagAtCaret(text.value, text.selectionStart);
    // A tag is a path: typing its last word ("build") finds "career/build" too.
    matches = at ? vocabulary.filter(v => v.tag !== at.query && (v.tag.startsWith(at.query) || (at.query && v.tag.split('/').some(part => part.startsWith(at.query))))).slice(0, 7) : [];
    suggest.hidden = !matches.length;
    suggest.innerHTML = matches.map((v, i) => `<button class="${i === 0 ? 'first' : ''}" data-tag="${esc(v.tag)}">
      <b>#${esc(v.tag)}</b><span>${esc(v.type === 'tag' ? 'tag' : v.label)}</span></button>`).join('')
      + (matches.length ? '<span class="muted">Tab to accept</span>' : '');
  }

  /// Replaces the hashtag being typed, or appends the tag at the caret.
  function insertTag(tag) {
    const caret = text.selectionStart;
    const at = L.tagAtCaret(text.value, caret);
    const start = at ? at.start : caret;
    const before = text.value.slice(0, start), after = text.value.slice(caret);
    const lead = before && !/\s$/.test(before) ? ' ' : '';
    const insert = lead + '#' + tag + (/^\s/.test(after) ? '' : ' ');
    text.value = before + insert + after;
    const pos = (before + insert).length;
    text.setSelectionRange(pos, pos);
    text.focus();
    renderSuggest();
  }

  function stageFiles(files) {
    for (const file of files) {
      const reader = new FileReader();
      reader.onload = () => post({ type: 'stageData', box: BOX, name: file.name || 'pasted.png', data: String(reader.result).split(',')[1] });
      reader.readAsDataURL(file);
    }
  }

  text.addEventListener('input', renderSuggest);
  text.addEventListener('click', renderSuggest);
  text.addEventListener('keydown', e => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(e.metaKey ? (e.shiftKey ? 'append' : 'send') : 'save'); }
    else if (e.key === 'Tab' && matches.length) { e.preventDefault(); insertTag(matches[0].tag); }
    else if (e.key === 'Escape') {
      e.preventDefault();
      if (matches.length) { matches = []; suggest.hidden = true; } else post({ type: 'hideCompose' });
    }
  });
  text.addEventListener('paste', e => {
    const files = [...(e.clipboardData?.files || [])];
    if (files.length) { e.preventDefault(); stageFiles(files); }
  });
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && e.target !== text) post({ type: 'hideCompose' });
  });
  document.addEventListener('click', e => {
    const tag = e.target.closest('[data-tag]');
    if (tag) return insertTag(tag.dataset.tag);
    const remove = e.target.closest('[data-remove]');
    if (remove) {
      const [gone] = staged.splice(+remove.dataset.remove, 1);
      if (gone) post({ type: 'unstage', name: gone.name });
      renderStaged();
    }
  });
  document.addEventListener('change', e => {
    const el = e.target.closest('[data-pick]');
    if (el) { pick[el.dataset.pick] = el.value; if (el.dataset.pick === 'agent') pick.model = ''; renderPick(); }
  });
  $('send').addEventListener('click', () => send('send'));
  $('append').addEventListener('click', () => send('append'));
  $('save').addEventListener('click', () => send('save'));
  $('shot').addEventListener('click', () => post({ type: 'screenshot', box: BOX }));
  $('file').addEventListener('click', () => post({ type: 'pickFiles', box: BOX }));
  $('open').addEventListener('click', () => post({ type: 'openWindow' }));

  window.TK = {
    receive(msg) {
      if (msg.type === 'state') renderHints(msg);
      else if (msg.type === 'staged') { staged.push(...msg.items); renderStaged(); text.focus(); }
      else if (msg.type === 'focus') text.focus();
    },
  };
  post({ type: 'ready' });
})();
