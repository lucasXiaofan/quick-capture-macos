// Skill Manager page. Swift (SkillDashboardController) scans folders and reads/writes files;
// this page does all the UI. Messages: page → Swift via webkit.messageHandlers.sm,
// Swift → page via SM.receive({type, ...}).
(function () {
  'use strict';
  const U = SkillUtil;
  const post = msg => { try { window.webkit.messageHandlers.sm.postMessage(msg); } catch (e) { /* not in the app */ } };
  const render = QCRender.createRenderer({ marked, katex, sanitize: html => DOMPurify.sanitize(html) });
  const $ = id => document.getElementById(id);
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

  const state = {
    skills: [], roots: [], showBuiltin: false, query: '',
    current: null,          // skill object
    rel: null,              // open file, relative to the skill folder
    content: '', editing: false, dirty: false, pending: null,
  };

  // ---------- Swift → page ----------

  window.SM = {
    receive(msg) {
      switch (msg.type) {
        case 'skills': return onSkills(msg);
        case 'file': return onFile(msg);
        case 'saved': return onSaved(msg);
        case 'created': return onCreated(msg);
        case 'error': return toast(msg.message, true);
      }
    },
  };

  function onSkills(msg) {
    state.skills = msg.skills.map(s => Object.assign(s, { files: U.sortFiles(s.files) }));
    state.roots = msg.roots;
    state.showBuiltin = !!msg.showBuiltin;
    $('builtin').checked = state.showBuiltin;
    if (state.current) {
      const again = state.skills.find(s => s.dir === state.current.dir);
      if (again) { state.current = again; renderSkillChrome(); } else goHome();
    }
    if (state.pending) { const p = state.pending; state.pending = null; openSkill(p.dir, p.rel, p.edit); }
    renderList();
    if (!state.current) renderHome();
  }

  function onFile(msg) {
    if (!state.current || msg.path !== path(state.current, state.rel)) return;
    state.content = msg.content;
    if (state.editing) { $('editor').value = msg.content; } else renderDoc();
  }

  function onSaved(msg) {
    if (state.current && msg.path === path(state.current, state.rel)) {
      state.content = $('editor').value;
      setEditing(false);
      renderDoc();
    }
    toast('Saved');
  }

  function onCreated(msg) {
    state.pending = { dir: msg.dir, rel: 'SKILL.md', edit: true };
    toast('Created ' + msg.name);
  }

  // ---------- Sidebar ----------

  function visibleSkills() {
    const q = state.query.trim().toLowerCase();
    return state.skills.filter(s => {
      if (s.builtin && !state.showBuiltin) return false;
      if (!q) return true;
      return s.name.toLowerCase().includes(q) || s.description.toLowerCase().includes(q)
        || s.files.some(f => f.toLowerCase().includes(q));
    });
  }

  function renderList() {
    const list = $('list');
    list.textContent = '';
    const skills = visibleSkills();
    const groups = new Map();
    for (const s of skills) {
      if (!groups.has(s.group)) groups.set(s.group, []);
      groups.get(s.group).push(s);
    }
    for (const [group, items] of groups) {
      list.appendChild(el('div', 'group', group));
      for (const s of items.sort((a, b) => a.name.localeCompare(b.name))) {
        const row = el('button', 'row' + (state.current && state.current.dir === s.dir ? ' active' : ''));
        row.dataset.dir = s.dir;
        row.appendChild(el('span', 'row-name', s.name));
        row.appendChild(el('span', 'row-desc', s.description || 'No description'));
        row.onclick = () => openSkill(s.dir);
        list.appendChild(row);
      }
    }
    if (!skills.length) list.appendChild(el('p', 'muted pad', state.query ? 'No match.' : 'No skills found.'));
  }

  // ---------- Home ----------

  function renderHome() {
    const cards = $('cards');
    cards.textContent = '';
    const skills = visibleSkills().slice().sort((a, b) => b.modified - a.modified);
    const mine = state.skills.filter(s => !s.builtin).length;
    $('home-sub').textContent = mine + (mine === 1 ? ' skill' : ' skills') + ' of your own'
      + (state.query ? ' · showing matches for “' + state.query + '”' : ' · newest first');
    for (const s of skills) {
      const card = el('button', 'card');
      const top = el('div', 'card-top');
      top.appendChild(el('span', 'card-name', s.name));
      if (s.builtin) top.appendChild(el('span', 'tag', 'built-in'));
      card.appendChild(top);
      card.appendChild(el('p', 'card-desc', s.description || 'No description'));
      const meta = el('div', 'card-meta');
      meta.appendChild(el('span', null, s.files.length + (s.files.length === 1 ? ' file' : ' files')));
      meta.appendChild(el('span', null, 'updated ' + U.ago(s.modified)));
      meta.appendChild(el('span', 'card-root', s.group));
      card.appendChild(meta);
      card.onclick = () => openSkill(s.dir);
      cards.appendChild(card);
    }
    $('empty').hidden = skills.length > 0;
    $('empty').textContent = state.query ? 'No skill matches “' + state.query + '”.' : 'No skills yet. Create one with New skill.';
  }

  function goHome() {
    if (!leaveEditor()) return;
    state.current = null; state.rel = null;
    $('skill').hidden = true; $('home').hidden = false;
    renderList(); renderHome();
  }

  // ---------- Skill view ----------

  function path(skill, rel) { return skill.dir + '/' + rel; }

  function openSkill(dir, rel, edit) {
    const skill = state.skills.find(s => s.dir === dir);
    if (!skill) return;
    if (state.current && state.current.dir === dir && !rel) return;
    if (!leaveEditor()) return;
    state.current = skill;
    $('home').hidden = true; $('skill').hidden = false;
    renderSkillChrome();
    renderList();
    openFile(rel || (skill.files.includes('SKILL.md') ? 'SKILL.md' : skill.files[0]), edit);
  }

  function renderSkillChrome() {
    const s = state.current;
    $('skill-name').textContent = s.name;
    $('skill-desc').textContent = s.description || 'No description in SKILL.md front matter.';
    $('skill-desc').classList.remove('open');
    const meta = $('skill-meta');
    meta.textContent = '';
    const where = el('button', 'chip link', s.displayDir);
    where.title = 'Show in Finder';
    where.onclick = () => post({ type: 'reveal', path: s.dir });
    meta.appendChild(where);
    meta.appendChild(el('span', 'chip', s.group));
    meta.appendChild(el('span', 'chip', s.files.length + (s.files.length === 1 ? ' file' : ' files')));
    meta.appendChild(el('span', 'chip', 'updated ' + U.ago(s.modified)));
    renderFiles();
  }

  function renderFiles() {
    const nav = $('files');
    nav.textContent = '';
    let folder = null;
    for (const f of state.current.files) {
      const dir = U.dirname(f);
      if (dir !== folder) {
        folder = dir;
        if (dir) nav.appendChild(el('div', 'folder', dir + '/'));
      }
      const b = el('button', 'file' + (f === state.rel ? ' active' : '') + (dir ? ' nested' : ''));
      const ext = U.extension(f);
      b.appendChild(el('span', 'ext ext-' + (ext || 'none'), (ext || '·').slice(0, 4)));
      b.appendChild(el('span', 'file-name', f.slice(dir ? dir.length + 1 : 0)));
      b.title = f;
      b.onclick = () => openFile(f);
      nav.appendChild(b);
    }
  }

  function openFile(rel, edit) {
    if (!rel || !state.current) return;
    if (rel !== state.rel && !leaveEditor()) return;
    state.rel = rel;
    state.content = '';
    renderFiles();
    $('crumb').textContent = state.current.name + ' / ' + rel;
    $('rendered').innerHTML = '<p class="muted">Loading…</p>';
    $('doc-scroll').scrollTop = 0;
    post({ type: 'read', path: path(state.current, rel) });
    if (edit) setEditing(true);
  }

  function renderDoc() {
    const rel = state.rel;
    const box = $('rendered');
    let html;
    if (U.extension(rel) === 'md') {
      const { meta, body } = U.parseFrontmatter(state.content);
      // SKILL.md's name and description are already in the header.
      if (rel === 'SKILL.md') { delete meta.name; delete meta.description; }
      html = metaTable(meta) + render(body);
    } else {
      html = render(U.fence(state.content, U.language(rel)));
    }
    box.innerHTML = html;
    box.querySelectorAll('pre code').forEach(code => { try { hljs.highlightElement(code); } catch (e) {} });
    linkPaths(box);
  }

  function metaTable(meta) {
    const keys = Object.keys(meta);
    if (!keys.length) return '';
    const esc = QCRender.escapeHtml;
    return '<dl class="front">' + keys.map(k => '<dt>' + esc(k) + '</dt><dd>' + esc(meta[k]) + '</dd>').join('') + '</dl>';
  }

  /// Inline `code` that names a file of this skill becomes a link to it.
  function linkPaths(box) {
    box.querySelectorAll('code').forEach(code => {
      if (code.closest('pre')) return;
      const hit = U.matchFile(code.textContent, state.rel, state.current.files);
      if (hit) { code.classList.add('path-link'); code.dataset.rel = hit; code.title = 'Open ' + hit; }
    });
  }

  $('rendered').addEventListener('click', e => {
    const code = e.target.closest('code.path-link');
    if (code) { e.preventDefault(); return openFile(code.dataset.rel); }
    const a = e.target.closest('a[href]');
    if (!a) return;
    e.preventDefault();
    const href = a.getAttribute('href');
    if (/^(https?|mailto):/i.test(href)) return post({ type: 'openURL', url: href });
    if (href.startsWith('#')) return;
    const hit = U.matchFile(href, state.rel, state.current.files);
    if (hit) return openFile(hit);
    const target = href.startsWith('/') || href.startsWith('~') ? href
      : state.current.dir + '/' + (U.resolvePath(U.dirname(state.rel), href.split('#')[0]) || '');
    post({ type: 'openPath', path: target });
  });

  // ---------- Editing ----------

  function setEditing(on) {
    state.editing = on;
    state.dirty = false;
    $('dirty').hidden = true;
    $('read-actions').hidden = on; $('edit-actions').hidden = !on;
    $('rendered').hidden = on; $('editor').hidden = !on;
    if (on) { $('editor').value = state.content; $('editor').focus(); $('editor').setSelectionRange(0, 0); $('editor').scrollTop = 0; }
  }

  /// Returns false if the user wants to keep editing.
  function leaveEditor() {
    if (!state.editing) return true;
    if (state.dirty && !confirm('Discard unsaved changes to ' + state.rel + '?')) return false;
    setEditing(false);
    return true;
  }

  function save() {
    if (!state.editing) return;
    post({ type: 'save', path: path(state.current, state.rel), content: $('editor').value });
  }

  $('editor').addEventListener('input', () => { state.dirty = true; $('dirty').hidden = false; });
  $('editor').addEventListener('keydown', e => {
    if (e.key === 'Tab') {            // Tab inserts two spaces instead of leaving the editor.
      e.preventDefault();
      const t = e.target, s = t.selectionStart;
      t.setRangeText('  ', s, t.selectionEnd, 'end');
      t.dispatchEvent(new Event('input'));
    }
  });
  $('skill-desc').onclick = e => e.currentTarget.classList.toggle('open');
  $('edit-btn').onclick = () => setEditing(true);
  $('save-btn').onclick = save;
  $('cancel-btn').onclick = () => { if (leaveEditor()) renderDoc(); };
  $('open-btn').onclick = () => post({ type: 'openPath', path: path(state.current, state.rel) });
  $('reveal-btn').onclick = () => post({ type: 'reveal', path: path(state.current, state.rel) });

  // ---------- New skill ----------

  function openNewDialog() {
    const select = $('new-root');
    select.textContent = '';
    for (const r of state.roots) {
      const o = el('option', null, r.label);
      o.value = r.path;
      select.appendChild(o);
    }
    $('new-name').value = ''; $('new-desc').value = '';
    validateName();
    $('new-dialog').showModal();
    $('new-name').focus();
  }

  function validateName() {
    const v = $('new-name').value.trim();
    const ok = U.NAME_RE.test(v);
    const exists = ok && state.skills.some(s => s.name === v && s.dir.startsWith($('new-root').value + '/'));
    $('new-name-hint').textContent = !v ? 'lowercase-kebab; becomes the folder name and the /command'
      : !ok ? 'Use lowercase letters, digits and single dashes' : exists ? 'A skill with this name already exists here' : 'Will create ' + $('new-root').selectedOptions[0]?.textContent + '/' + v + '/SKILL.md';
    $('new-name-hint').className = v && (!ok || exists) ? 'bad' : '';
    $('new-create').disabled = !ok || exists || !state.roots.length;
  }

  $('new-name').addEventListener('input', validateName);
  $('new-root').addEventListener('change', validateName);
  $('new-cancel').onclick = () => $('new-dialog').close();
  $('new-form').addEventListener('submit', e => {
    e.preventDefault();
    post({ type: 'create', root: $('new-root').value, name: $('new-name').value.trim(), description: $('new-desc').value.trim() });
    $('new-dialog').close();
  });
  $('new-btn').onclick = openNewDialog;
  $('new-btn-2').onclick = openNewDialog;

  // ---------- Search, footer, keys ----------

  const search = $('search');
  search.addEventListener('input', () => { state.query = search.value; renderList(); if (!state.current) renderHome(); });
  search.addEventListener('keydown', e => {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp' || e.key === 'Enter') {
      const rows = [...document.querySelectorAll('#list .row')];
      if (!rows.length) return;
      e.preventDefault();
      let i = rows.findIndex(r => r.classList.contains('active'));
      i = e.key === 'Enter' ? Math.max(i, 0) : e.key === 'ArrowDown' ? Math.min(i + 1, rows.length - 1) : Math.max(i - 1, 0);
      openSkill(rows[i].dataset.dir);
      rows[i].scrollIntoView({ block: 'nearest' });
    }
  });

  $('builtin').onchange = e => post({ type: 'setShowBuiltin', value: e.target.checked });
  $('add-folder').onclick = () => post({ type: 'addFolder' });
  $('refresh').onclick = () => { post({ type: 'refresh' }); if (state.current && state.rel && !state.editing) post({ type: 'read', path: path(state.current, state.rel) }); };
  $('home-btn').onclick = goHome;

  document.addEventListener('keydown', e => {
    const cmd = e.metaKey || e.ctrlKey;
    if (cmd && e.key === 'f') { e.preventDefault(); search.focus(); search.select(); }
    else if (cmd && e.key === 'n') { e.preventDefault(); openNewDialog(); }
    else if (cmd && e.key === 's') { e.preventDefault(); save(); }
    else if (cmd && e.key === 'e' && state.current && !state.editing) { e.preventDefault(); setEditing(true); }
    else if (e.key === 'Escape' && !$('new-dialog').open) {
      if (state.editing) { if (leaveEditor()) renderDoc(); }
      else if (document.activeElement === search && search.value) { search.value = ''; search.dispatchEvent(new Event('input')); }
    }
  });

  let toastTimer;
  function toast(text, bad) {
    const t = $('toast');
    t.textContent = text;
    t.className = 'show' + (bad ? ' bad' : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.className = ''; }, bad ? 4000 : 1800);
  }

  post({ type: 'ready' });
})();
