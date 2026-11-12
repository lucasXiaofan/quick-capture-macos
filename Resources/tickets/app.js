// The Tickets window. Swift owns the files and the agent; this page draws every view from the flat list
// of tickets. Page → Swift via webkit.messageHandlers.tk, Swift → page via TK.receive.
(function () {
  const L = TKLogic;
  const post = msg => { try { window.webkit.messageHandlers.tk.postMessage(msg); } catch (e) { /* not in the app */ } };
  const markdown = QCRender.createRenderer({ marked, katex, sanitize: html => DOMPurify.sanitize(html) });
  const nav = document.getElementById('nav'), main = document.getElementById('main'), toastBox = document.getElementById('toast');

  /// What Swift sent last.
  let S = { tickets: [], structure: { kinds: [], projects: [] }, instructions: '', corrections: [], decisions: [],
    designs: [], tools: [], tagRules: { indexMax: 30, fileMax: 15, folder: '', problems: [], map: false }, prompt: '', contract: '', selfUpdate: { enabled: false, problem: '', folder: '', busy: false, records: [] }, busy: {}, today: new Date().toISOString().slice(0, 10), settings: {} };
  let loaded = false;
  /// What the user is looking at.
  const UI = { view: 'inbox', filter: 'you', kind: '', query: '', selected: null, project: null, agentTab: 'instructions',
    staged: {}, panel: null, weeks: 26, pick: { agent: '', model: '', effort: '' }, design: null, ctxOpen: {} };
  /// The canvas on screen: { id, api, timer, stamp }. It lives outside render(), which would wipe it.
  let board = null;
  const SYSTEM_DESIGNS = [
    { id: 'sys:system', title: 'How the ticket system works', summary: 'Your input → what the agent is told → its action space and tools → files → views.', build: () => L.systemDesign(S) },
    { id: 'sys:categories', title: 'How a capture is categorized', summary: 'Kind, project, tags and status — drawn from the current kinds, projects and tags.', build: () => L.categorizationDesign(S) },
  ];

  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const kindOf = id => S.structure.kinds.find(k => k.id === id) || { id, label: id, icon: '🏷', view: 'thread' };
  const projectOf = id => S.structure.projects.find(p => p.id === id) || { id, name: id, type: 'personal' };
  const ticket = id => S.tickets.find(t => t.id === id);
  const visible = () => L.visible(S.tickets);
  const busy = id => S.busy[String(id)];
  const fmtDay = day => day ? new Date(day + 'T12:00:00').toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) : '';
  const fmtTime = stamp => stamp ? new Date(stamp).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '';
  const STATUS = {
    unprocessed: { label: 'New', hint: 'No agent has looked at it yet' },
    needs_agent: { label: 'Agent’s turn', hint: 'In progress — waiting for the agent' },
    waiting_human: { label: 'Your turn', hint: 'In progress — waiting for you' },
    closed: { label: 'Closed', hint: 'Done' },
  };
  const FILTERS = [
    ['you', 'Your turn', t => t.status === 'waiting_human'],
    ['agent', 'Agent’s turn', t => t.status === 'unprocessed' || t.status === 'needs_agent'],
    ['open', 'All open', t => t.status !== 'closed'],
    ['closed', 'Closed', t => t.status === 'closed'],
  ];
  const VIEWS = [['projects', 'Projects', '◫'], ['habits', 'Habits', '▦'], ['plan', 'Plan', '▤'], ['library', 'Library', '❏'], ['tags', 'Tags', '#'], ['agent', 'Agent', '✦']];

  /// The agent and effort chosen for the next run ('' = the defaults from Settings).
  function pickFields() {
    const out = {};
    if (UI.pick.agent) out.agent = UI.pick.agent;
    if (UI.pick.model) out.model = UI.pick.model;
    if (UI.pick.effort) out.effort = UI.pick.effort;
    return out;
  }
  const modelLabel = (agent, id) => (agent.models.find(m => m.id === id) || { label: id }).label;
  function pickControls() {
    const agents = S.settings.agents || [];
    if (!agents.length) return '';
    const current = agents.find(a => a.id === (UI.pick.agent || S.settings.agentID)) || agents[0];
    const def = agents.find(a => a.id === S.settings.agentID) || agents[0];
    return `<select class="pick" data-pick="agent" title="Which agent answers this time">
        <option value="">${esc(def.name)} (default)</option>
        ${agents.filter(a => a.id !== def.id).map(a => `<option value="${a.id}" ${UI.pick.agent === a.id ? 'selected' : ''}>${esc(a.name)}${a.installed ? '' : ' (not installed)'}</option>`).join('')}
      </select>
      <select class="pick" data-pick="model" title="Which model answers this time">
        <option value="">${current.model ? esc(modelLabel(current, current.model)) + ' (default)' : 'default model'}</option>
        ${current.models.filter(m => m.id !== current.model).map(m => `<option value="${esc(m.id)}" ${UI.pick.model === m.id ? 'selected' : ''}>${esc(m.label)}</option>`).join('')}
      </select>
      <select class="pick" data-pick="effort" title="Reasoning effort for this time">
        <option value="">${current.effort ? esc(current.effort) + ' (default)' : 'default effort'}</option>
        ${current.efforts.filter(e => e !== current.effort).map(e => `<option ${UI.pick.effort === e ? 'selected' : ''}>${e}</option>`).join('')}
      </select>`;
  }

  const mdCache = new Map();
  function md(text) {
    if (!mdCache.has(text)) {
      if (mdCache.size > 600) mdCache.clear();
      mdCache.set(text, markdown(text));
    }
    return mdCache.get(text);
  }

  function toast(message) {
    toastBox.textContent = message;
    toastBox.classList.add('show');
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => toastBox.classList.remove('show'), 3200);
  }

  // MARK: Chips

  const kindChip = id => { const k = kindOf(id); return `<span class="chip kind" title="${esc(k.label)}">${esc(k.icon)} ${esc(k.label)}</span>`; };
  const projectChip = id => id ? `<button class="chip project" style="--h:${L.hue(id)}" data-act="project" data-project="${esc(id)}">${esc(projectOf(id).name)}</button>` : '';
  const statusDot = t => busy(t.id) ? '<span class="dot working" title="The agent is working"></span>'
    : `<span class="dot ${t.status}" title="${esc(STATUS[t.status]?.hint || '')}"></span>`;
  const ticketLink = (id, label) => `<button class="link" data-act="open" data-id="${id}">${label ?? '#' + id}</button>`;

  // MARK: Sidebar

  function renderNav() {
    const all = visible();
    const count = f => all.filter(f).length;
    nav.innerHTML = `
      <button class="primary new" data-act="compose">＋ New ticket</button>
      <div class="nav-group">Inbox</div>
      ${FILTERS.map(([id, label, f]) => `
        <button class="nav-item ${UI.view === 'inbox' && UI.filter === id ? 'on' : ''}" data-act="filter" data-filter="${id}">
          <span class="dot ${id === 'you' ? 'waiting_human' : id === 'agent' ? 'needs_agent' : id === 'closed' ? 'closed' : 'open'}"></span>
          <span>${label}</span><span class="count ${id === 'you' && count(f) ? 'hot' : ''}">${count(f) || ''}</span>
        </button>`).join('')}
      <div class="nav-group">Views</div>
      ${VIEWS.map(([id, label, glyph]) => `
        <button class="nav-item ${UI.view === id ? 'on' : ''}" data-act="view" data-view="${id}">
          <span class="glyph">${glyph}</span><span>${label}</span>
        </button>`).join('')}
      <div class="spacer"></div>
      <button class="agent-chip ${S.settings.installed === false ? 'bad' : ''}" data-act="settings" title="${esc(S.settings.accessNote || '')}&#10;Click to change the agent and what it may do.">
        <b>${esc(S.settings.agent || 'Agent')}</b>
        <span>${S.settings.installed === false ? 'not installed' : esc({ read_only: 'read only', workspace: 'workspace access', full: 'full access' }[S.settings.access] || '')}${S.settings.auto === false ? ' · manual' : ''}</span>
      </button>`;
  }

  // MARK: Inbox

  function inboxList() {
    const filter = FILTERS.find(f => f[0] === UI.filter) || FILTERS[2];
    const base = visible().filter(filter[2]);
    const kinds = [...new Set(base.map(t => t.kind))];
    const rows = base.filter(t => (!UI.kind || t.kind === UI.kind) && L.matches(t, UI.query));
    const row = t => {
      const last = t.messages[t.messages.length - 1];
      const b = busy(t.id);
      return `<button class="row ${t.id === UI.selected ? 'on' : ''} ${t.status}" data-act="open" data-id="${t.id}">
        ${statusDot(t)}
        <span class="row-main">
          <span class="row-top"><span class="row-title">${esc(kindOf(t.kind).icon)} ${esc(t.title)}</span><time>${L.ago(t.updated)}</time></span>
          <span class="row-snippet">${b ? `<i>${esc(b.activity)}</i>` : esc((last && last.role === 'agent' ? '↩ ' : '') + L.snippet(last ? last.text : '', 120))}</span>
          <span class="row-meta">${t.project ? `<span class="chip project" style="--h:${L.hue(t.project)}">${esc(projectOf(t.project).name)}</span>` : ''}
            ${t.due ? `<span class="chip due ${L.dueBucket(t.due, S.today)}">${t.start ? fmtDay(t.start) + ' → ' : 'due '}${fmtDay(t.due)}${t.due_time ? ' ' + esc(t.due_time) : ''}</span>` : ''}
            ${(t.tags || []).filter(x => !L.internalTag(x)).slice(0, 3).map(x => `<span class="chip tag">#${esc(x)}</span>`).join('')}
            ${(t.merged_from || []).length ? `<span class="chip">⑂ ${t.merged_from.length} merged</span>` : ''}
            <span class="num">#${t.id}</span></span>
        </span></button>`;
    };
    return `<section class="list">
      <div class="list-head">
        <input type="search" data-keep="search" data-input="query" placeholder="Search tickets, #tags, projects" value="${esc(UI.query)}">
        <div class="kind-filter">
          <button class="pill ${UI.kind ? '' : 'on'}" data-act="kind" data-kind="">All ${base.length}</button>
          ${kinds.map(k => `<button class="pill ${UI.kind === k ? 'on' : ''}" data-act="kind" data-kind="${esc(k)}">${esc(kindOf(k).icon)} ${esc(kindOf(k).label)}</button>`).join('')}
        </div>
      </div>
      <div class="rows" data-scroll="rows">${rows.map(row).join('') || `<p class="empty">${emptyText()}</p>`}</div>
    </section><div class="resizer" data-resize="list" title="Drag to resize · double-click to reset"></div>`;
  }

  function emptyText() {
    if (!S.tickets.length) return 'No tickets yet. Press <b>＋ New ticket</b> or your shortcut and write anything.';
    if (UI.query || UI.kind) return 'Nothing matches.';
    return { you: 'Nothing is waiting for you. 🎉', agent: 'The agent has nothing to do.', open: 'No open tickets.', closed: 'Nothing closed yet.' }[UI.filter];
  }

  function attachments(t, m) {
    if (!(m.attachments || []).length) return '';
    return `<div class="atts">${m.attachments.map(name => {
      const src = `tkfile://a/${t.id}/${encodeURIComponent(name)}`;
      const image = /\.(png|jpe?g|gif|webp|heic|tiff|bmp)$/i.test(name);
      return `<button class="att ${image ? 'image' : ''}" data-act="attachment" data-id="${t.id}" data-name="${esc(name)}" title="Open ${esc(name)}">
        ${image ? `<img src="${src}" alt="${esc(name)}" loading="lazy">` : `📎 ${esc(name)}`}</button>`;
    }).join('')}</div>`;
  }

  function message(t, m) {
    const who = m.role === 'human' ? 'You' : m.role === 'agent' ? 'Agent' : 'Note';
    const steps = (m.tools || []).length
      ? `<details class="steps"><summary>${m.tools.length} step${m.tools.length === 1 ? '' : 's'} the agent took</summary><ol>${m.tools.map(s => `<li>${esc(s)}</li>`).join('')}</ol></details>` : '';
    return `<article class="msg ${esc(m.role)}">
      <header><span class="avatar">${m.role === 'human' ? '🙂' : m.role === 'agent' ? '✦' : '!'}</span>
        <b>${who}</b>${m.agent ? `<span class="muted">${esc(m.agent)}</span>` : ''}
        ${m.from ? `<span class="muted">from ${ticketLink(m.from)}</span>` : ''}
        <time title="${esc(m.at)}">${fmtTime(m.at)}</time></header>
      <div class="md">${md(m.text)}</div>${attachments(m.from ? { id: t.id } : t, m)}${steps}
    </article>`;
  }

  function stagedChips(box) {
    return (UI.staged[box] || []).map((s, i) => `<span class="chip file">
      ${s.image ? `<img src="tkfile://s/${encodeURIComponent(s.name)}" alt="">` : '📎'}<span>${esc(s.name)}</span>
      <button data-act="unstage" data-box="${esc(box)}" data-index="${i}" title="Remove">×</button></span>`).join('');
  }

  function thread(t) {
    const b = busy(t.id);
    const box = 'reply:' + t.id;
    const kinds = S.structure.kinds.map(k => `<option value="${esc(k.id)}" ${k.id === t.kind ? 'selected' : ''}>${esc(k.icon)} ${esc(k.label)}</option>`).join('');
    const merged = t.merged_into != null;
    const panel = UI.panel && UI.panel.id === t.id ? UI.panel.type : null;
    return `<section class="thread">
      <div class="thread-scroll" data-scroll="thread:${t.id}">
      <header class="thread-head">
        <div class="title-row">
          ${statusDot(t)}
          <input class="title" data-keep="title:${t.id}" data-change="title" data-id="${t.id}" value="${esc(t.title)}" title="Rename">
          <span class="num">#${t.id}</span>
        </div>
        ${merged ? `<p class="banner">Merged into ${ticketLink(t.merged_into)}. This original is kept as it was; continue on the merged ticket.</p>` : ''}
        <div class="props">
          <span class="status-pill ${t.status}" title="${esc(STATUS[t.status]?.hint || '')}">${esc(STATUS[t.status]?.label || t.status)}</span>
          <label>Kind <select data-change="kind" data-id="${t.id}">${kinds}</select></label>
          <label>Related project IDs <input data-keep="related:${t.id}" data-change="related_projects" data-id="${t.id}" value="${esc((t.related_projects || []).join(', '))}" placeholder="project-id, another-id"></label>
          <label>Project <input list="projects" data-keep="project:${t.id}" data-change="project" data-id="${t.id}" value="${esc(t.project ? projectOf(t.project).name : '')}" placeholder="none"></label>
          <label>Start <input type="date" data-change="start" data-id="${t.id}" value="${esc(t.start || '')}"></label>
          <label>Due <input type="date" data-change="due" data-id="${t.id}" value="${esc(t.due || '')}">
            ${t.due ? `<input type="time" data-change="due_time" data-id="${t.id}" value="${esc(t.due_time || '')}" title="Time of day (optional). With a time you are reminded a few hours before; without, that morning.">` : ''}</label>
        </div>
        <div class="tag-edit"><span class="muted">Tags</span>
          ${(t.tags || []).filter(x => !L.internalTag(x)).map(x => { const def = (S.structure.tags || []).find(d => d.id === x);
            return `<span class="chip tag ${def && def.meaning ? '' : 'loose'}" title="${esc(def && def.meaning ? def.meaning + (def.action ? ' → ' + def.action : '') : 'No meaning yet — define it under Tags')}">#${esc(x)}<button data-act="removeTag" data-id="${t.id}" data-tag="${esc(x)}" title="Remove">×</button></span>`; }).join('')}
          <form class="inline slim" data-submit="addTag" data-id="${t.id}"><input name="text" list="taglist" data-keep="addtag:${t.id}" placeholder="＋ tag"></form>
        </div>
        <div class="actions">
          ${t.status === 'closed' ? `<button class="ghost" data-act="status" data-id="${t.id}" data-status="waiting_human">Reopen</button>`
            : `<button class="ghost" data-act="status" data-id="${t.id}" data-status="closed">✓ Close</button>`}
          ${b ? `<button class="ghost" data-act="stop" data-id="${t.id}">■ Stop agent</button>` : `<button class="ghost" data-act="run" data-id="${t.id}" ${merged ? 'disabled' : ''} title="Run the agent now, with the agent and effort picked in the reply box">✦ Run agent</button>`}
          <button class="ghost ${panel === 'correct' ? 'on' : ''}" data-act="panel" data-panel="correct" data-id="${t.id}" title="Tell the agent what it got wrong; it is added to its prompt from now on">✎ Correct agent</button>
          <button class="ghost ${panel === 'merge' ? 'on' : ''}" data-act="panel" data-panel="merge" data-id="${t.id}" ${merged ? 'disabled' : ''}>⑂ Merge</button>
          <span class="spacer"></span>
          <button class="ghost" data-act="reveal" data-id="${t.id}" title="Show the ticket's Markdown file in Finder">File</button>
          ${(t.merged_from || []).length ? `<button class="ghost" data-act="unmerge" data-id="${t.id}" title="Delete this merged ticket and bring back the originals">Unmerge</button>` : ''}
          <button class="ghost danger" data-act="delete" data-id="${t.id}">Delete</button>
        </div>
        ${panel === 'correct' ? `<form class="inline" data-submit="correction" data-id="${t.id}">
            <input name="text" data-keep="correct:${t.id}" placeholder="What did the agent get wrong? e.g. “Practice questions for a course are exam review, not question.”" autofocus>
            <button class="primary">Log correction</button></form>` : ''}
        ${panel === 'merge' ? mergePanel(t) : ''}
        ${t.summary ? `<blockquote class="summary">${esc(t.summary)}</blockquote>` : ''}
        ${S.selfUpdate.records.filter(r => r.ticket === t.id).slice(0, 1).map(r => `<p class="merged-from">🛠 Changed the app's source (${r.files.length} file${r.files.length === 1 ? '' : 's'}) — <button class="link" data-act="agentUpdates">${esc(({ pending: 'not rebuilt yet', building: 'building', ok: 'running', build_failed: 'build failed', rolled_back: 'rolled back', reverted: 'rolled back' })[r.result] || r.result)}</button></p>`).join('')}
        ${(t.merged_from || []).length ? `<p class="merged-from">⑂ Merged from ${t.merged_from.map(id => ticketLink(id, '#' + id + (ticket(id) ? ' ' + esc(ticket(id).title) : ''))).join(' · ')}</p>` : ''}
        <div class="takeaways">
          ${(t.takeaways || []).map(text => `<span class="takeaway">💡 ${esc(text)}<button data-act="removeTakeaway" data-id="${t.id}" data-text="${esc(text)}" title="Remove">×</button></span>`).join('')}
          <form class="inline slim" data-submit="takeaway" data-id="${t.id}"><input name="text" data-keep="takeaway:${t.id}" placeholder="＋ takeaway"></form>
        </div>
        ${(t.log || []).length ? `<div class="log">${t.log.map(e => `<span class="chip" title="${esc(e.note || '')}">🔁 ${esc(e.name)} · ${fmtDay(e.date)}${e.value != null ? ' · ' + e.value + (e.unit ? ' ' + esc(e.unit) : '') : ''}
            <button data-act="removeLog" data-id="${t.id}" data-date="${esc(e.date)}" data-name="${esc(e.name)}" title="Remove this entry">×</button></span>`).join('')}</div>` : ''}
      </header>
      <div class="messages">
        ${t.messages.map(m => message(t, m)).join('')}
        ${b ? `<article class="msg agent working"><header><span class="avatar spin">✦</span><b>Agent</b>
            <span class="muted">${b.queued ? 'queued' : 'working'}</span></header>
            <div class="activity">${esc(b.activity)}</div>
            ${(b.tools || []).length > 1 ? `<details class="steps"><summary>${b.tools.length} steps so far</summary><ol>${b.tools.map(s => `<li>${esc(s)}</li>`).join('')}</ol></details>` : ''}</article>` : ''}
        ${(t.history || []).length ? `<details class="history"><summary>History (${t.history.length})</summary><ul>
          ${t.history.map(h => `<li><time>${fmtTime(h.at)}</time> <b>${esc(h.by)}</b> ${esc(h.text)}</li>`).join('')}</ul></details>` : ''}
      </div>
      </div>
      ${merged ? '' : `<footer class="reply">
        <textarea data-keep="${box}" data-box="${box}" placeholder="Reply… ⌘↩ send to the agent · ⌃↩ add as a note · paste or drop images" rows="3"></textarea>
        <div class="staged">${stagedChips(box)}</div>
        <div class="reply-bar">
          <button class="ghost" data-act="screenshot" data-box="${box}">Screenshot</button>
          <button class="ghost" data-act="pickFiles" data-box="${box}">File</button>
          <span class="reply-picks">${pickControls()}</span>
          <span class="reply-actions">
            <button class="ghost" data-act="note" data-id="${t.id}" title="Add to the ticket without asking the agent to reply (⌃↩)">Add as note <kbd>⌃↩</kbd></button>
            <button class="primary" data-act="reply" data-id="${t.id}" title="Send to the agent (⌘↩)">Send <kbd>⌘↩</kbd></button>
          </span>
        </div>
      </footer>`}
    </section>`;
  }

  function mergePanel(t) {
    const candidates = visible().filter(o => o.id !== t.id && (o.project && o.project === t.project || o.kind === t.kind)).slice(0, 12);
    return `<form class="inline merge" data-submit="merge" data-id="${t.id}">
      <input name="ids" data-keep="merge:${t.id}" placeholder="Ticket numbers to merge with this one, e.g. 12 15" autofocus>
      <button class="primary">Merge</button>
      <p class="muted">Makes one new ticket with every message, in time order. The originals are kept untouched and can be brought back with Unmerge.
        ${candidates.length ? '<br>Related: ' + candidates.map(o => `<button type="button" class="link" data-act="mergeAdd" data-id="${t.id}" data-other="${o.id}">#${o.id} ${esc(o.title)}</button>`).join(' · ') : ''}</p>
    </form>`;
  }

  function renderInbox() {
    const t = UI.selected != null ? ticket(UI.selected) : null;
    main.className = 'inbox';
    main.innerHTML = inboxList() + (t ? thread(t) : `<section class="thread blank"><div>
      <h2>${S.tickets.length ? 'Pick a ticket' : 'Capture anything'}</h2>
      <p>A ticket can be a todo, a question, an idea, a habit check-in, a bug, a meeting note, a link worth keeping.
      The agent classifies it, takes the first turn, and you answer like email.</p>
      <button class="primary" data-act="compose">＋ New ticket</button></div></section>`)
      + `<datalist id="projects">${S.structure.projects.map(p => `<option value="${esc(p.name)}">`).join('')}</datalist>
        <datalist id="taglist">${(S.structure.tags || []).map(x => `<option value="${esc(x.id)}">${esc(x.meaning)}</option>`).join('')}</datalist>`;
  }

  // MARK: Projects

  function activityStrip(days, n = 42) {
    const set = new Set(days);
    let out = '';
    for (let i = n - 1; i >= 0; i--) {
      const day = L.addDays(S.today, -i);
      out += `<i class="${set.has(day) ? 'on' : ''}" title="${fmtDay(day)}"></i>`;
    }
    return `<div class="strip" title="Last ${n} days">${out}</div>`;
  }

  function renderProjects() {
    main.className = 'page';
    if (UI.project && S.structure.projects.some(p => p.id === UI.project)) return renderProject(projectOf(UI.project));
    const stats = {};
    for (const p of S.structure.projects) stats[p.id] = L.projectStats(p.id, S.tickets, S.today, p.context_ticket_ids || []);
    const loose = visible().filter(t => !t.project && t.status !== 'closed').length;
    const card = p => {
      const s = stats[p.id], top = L.topTickets(s.tickets, S.today, 3);
      const designs = S.designs.filter(d => d.project === p.id).length;
      return `<article class="card project-card" style="--h:${L.hue(p.id)}" data-act="project" data-project="${esc(p.id)}">
          <header><h3>${esc(p.name)}</h3>
            <button class="star ${p.important ? 'on' : ''}" data-act="important" data-project="${esc(p.id)}" title="Important: worth making visible">★</button></header>
          <div class="big"><b>${s.usedDays}</b><span>used day${s.usedDays === 1 ? '' : 's'}</span>
            <span class="muted">${s.idleDays == null ? 'no activity yet' : s.idleDays === 0 ? 'active today' : s.idleDays + 'd since last touch'}</span></div>
          ${activityStrip(s.days)}
          <div class="top-tickets">${top.map(t => `<button class="top" data-act="open" data-id="${t.id}" title="${esc(STATUS[t.status]?.label || '')} · open ticket #${t.id}">
              ${statusDot(t)}<span>${esc(kindOf(t.kind).icon)} ${esc(t.title)}</span>
              ${t.due ? `<span class="chip due ${L.dueBucket(t.due, S.today)}">${fmtDay(t.due)}</span>` : ''}</button>`).join('')
            || '<p class="muted">Nothing open.</p>'}</div>
          <footer><span>${s.open} open · ${s.closed} closed${designs ? ` · ${designs} design${designs === 1 ? '' : 's'}` : ''}${s.open > top.length ? ` · <u>${s.open - top.length} more</u>` : ''}</span>
            ${s.shipped ? `<span class="ship done">🚀 shipped ×${s.shipped}</span>` : s.shipping ? '<span class="ship">🚀 shipping in progress</span>'
              : L.shipNudge(p, s) ? '<span class="ship nudge">🚀 not visible yet — ship something</span>' : ''}</footer>
        </article>`;
    };
    const groups = L.groupProjects(S.structure.projects);
    main.innerHTML = `<header class="page-head"><h1>Projects</h1>
        <p class="muted">Grouped by category, each with the three tickets most worth a look (due soonest, then waiting for you). A <b>used day</b> is any day a project got attention — one minute or ten hours.</p></header>
      ${groups.map(g => `<section class="category"><h2 class="pad">${esc(g.category)} <span class="count">${g.projects.length}</span></h2>
        <div class="cards">${g.projects.slice().sort((a, b) => (stats[b.id].lastDay || '').localeCompare(stats[a.id].lastDay || '')).map(card).join('')}</div></section>`).join('')
        || '<p class="empty pad">No projects yet. The agent creates one when a ticket clearly belongs to something, or type a name in a ticket’s Project field.</p>'}
      ${loose ? `<p class="muted pad loose">${loose} open ticket${loose === 1 ? '' : 's'} belong to no project. <button class="link" data-act="filter" data-filter="open">Show open tickets</button></p>` : ''}`;
  }

  function miniRow(t) {
    return `<button class="mini" data-act="open" data-id="${t.id}">${statusDot(t)}<span>${esc(kindOf(t.kind).icon)} ${esc(t.title)}</span>
      ${t.due ? `<span class="chip due ${L.dueBucket(t.due, S.today)}">${fmtDay(t.due)}${t.due_time ? ' ' + esc(t.due_time) : ''}</span>` : ''}<span class="num">#${t.id}</span></button>`;
  }

  /// A project on one screen: where it stands, what needs attention, what happened lately — then the detail.
  function renderProject(p) {
    const s = L.projectStats(p.id, S.tickets, S.today, p.context_ticket_ids || []);
    const open = L.topTickets(s.tickets, S.today, 999);
    const experiments = s.tickets.filter(t => t.kind === 'experiment');
    const shipping = s.tickets.filter(t => t.kind === 'shipping');
    const plans = s.tickets.filter(t => t.kind === 'plan').sort((a, b) => (a.start || a.due || '9').localeCompare(b.start || b.due || '9'));
    const ctx = L.contextSections(p.context);
    const hero = ctx.sections.find(x => !x.log) || (ctx.intro ? { title: 'Where it stands', body: ctx.intro } : null);
    const cards = ctx.sections.filter(x => x !== hero);
    const days = L.timeline(s.tickets);
    const recent = days.slice(0, 4);
    const waiting = open.filter(t => t.status === 'waiting_human').length;
    const overdue = open.filter(t => L.dueBucket(t.due, S.today) === 'overdue').length;
    const stat = (n, label, cls = '') => `<span class="stat ${cls}"><b>${n}</b>${label}</span>`;
    const clamp = (key, body, limit) => {
      const long = body.length > limit || body.split('\n').length > 7;
      const isOpen = !!UI.ctxOpen[p.id + ':' + key];
      return `<div class="md ctx-body ${long && !isOpen ? 'clamp' : ''}">${md(body || '_Nothing written yet._')}</div>
        ${long ? `<button class="link more" data-act="ctxToggle" data-key="${esc(p.id + ':' + key)}">${isOpen ? 'Show less' : 'Show all'}</button>` : ''}`;
    };
    const planRow = t => {
      const late = t.status !== 'closed' && t.due && t.due < S.today, now = t.status !== 'closed' && t.start && t.start <= S.today && (!t.due || t.due >= S.today);
      return `<button class="plan-row ${t.status} ${late ? 'late' : now ? 'now' : ''}" data-act="open" data-id="${t.id}">${statusDot(t)}
        <span class="when">${t.start ? fmtDay(t.start) : ''}${t.start && t.due ? ' → ' : ''}${t.due ? fmtDay(t.due) : ''}</span>
        <span class="what">${esc(t.title)}</span>${late ? '<span class="chip due overdue">late</span>' : now ? '<span class="chip due today">now</span>' : t.status === 'closed' ? '<span class="chip">done</span>' : ''}</button>`;
    };
    main.innerHTML = `<header class="page-head project-head" style="--h:${L.hue(p.id)}">
        <button class="link" data-act="project" data-project="">← Projects</button>
        <div class="project-title"><h1><span class="swatch"></span>${esc(p.name)}
            <button class="star ${p.important ? 'on' : ''}" data-act="important" data-project="${esc(p.id)}" title="Important: worth making visible">★</button></h1>
          <div class="stat-row">${stat(s.usedDays, 'used day' + (s.usedDays === 1 ? '' : 's'))}${stat(s.open, 'open')}
            ${waiting ? stat(waiting, 'waiting for you', 'you') : ''}${overdue ? stat(overdue, 'overdue', 'bad') : ''}
            ${stat(s.closed, 'closed')}${stat(s.takeaways.length, 'takeaway' + (s.takeaways.length === 1 ? '' : 's'))}${stat(s.shipped, 'shipped', s.shipped ? 'done' : '')}
            <span class="stat muted">${s.idleDays == null ? 'no activity yet' : s.idleDays === 0 ? 'active today' : 'last touched ' + s.idleDays + 'd ago'}</span></div></div>
        ${activityStrip(s.days, 90)}
        <div class="props">
          <label>Category <input list="categories" data-keep="ptype:${esc(p.id)}" data-change="projectType" data-project="${esc(p.id)}" value="${esc(p.type || 'personal')}" title="Projects are grouped by this on the Projects page">
            <datalist id="categories">${[...new Set(['research', 'class', 'personal', ...S.structure.projects.map(x => x.type)])].map(x => `<option value="${esc(x)}">`).join('')}</datalist></label>
          <label class="grow">Note for the agent <input data-keep="pnote:${esc(p.id)}" data-change="projectNote" data-project="${esc(p.id)}" value="${esc(p.note || '')}" placeholder="e.g. code lives in ~/code/gptluna; it is the IR course this fall"></label>
        </div>
        ${L.shipNudge(p, s) ? `<p class="banner ship">🚀 ${s.usedDays} used days and nothing visible yet. Make it something others can use or see — a paper, a video, a post.
          <button class="ghost" data-act="shipTicket" data-project="${esc(p.id)}">Start a shipping ticket</button></p>` : ''}
      </header>
      <div class="glance">
        <article class="card g-card stands"><h2>${esc(hero ? hero.title : 'Where it stands')}</h2>
          ${hero ? clamp('hero', hero.body, 700) : '<p class="empty">No context yet. Write the goal and current state under Project context below, or let the agent maintain it.</p>'}</article>
        <article class="card g-card"><h2>Needs attention <span class="count">${open.length || ''}</span></h2>
          ${open.slice(0, 6).map(miniRow).join('') || '<p class="empty">Nothing open.</p>'}
          ${open.length > 6 ? `<details class="more-open"><summary>${open.length - 6} more open</summary>${open.slice(6).map(miniRow).join('')}</details>` : ''}</article>
        <article class="card g-card"><h2>Recently</h2>
          ${recent.map(d => `<div class="day"><time>${d.day === S.today ? 'Today' : fmtDay(d.day)}</time><div>${d.items.slice(0, 4).map(i =>
            `<button class="event" data-act="open" data-id="${i.ticket}"><b>${esc(kindOf(i.kind).icon)} ${esc(i.title)}</b><span>${esc(i.what)}</span></button>`).join('')}
            ${d.items.length > 4 ? `<p class="muted sub">+${d.items.length - 4} more that day</p>` : ''}</div></div>`).join('') || '<p class="empty">Nothing yet.</p>'}</article>
      </div>
      <section class="pad"><h2>Plan <span class="count">${plans.length || ''}</span></h2>
        <div class="plan-rows">${plans.map(planRow).join('') || '<p class="empty">No plan tickets yet. Plans need Start and Due dates to appear in the Plan view.</p>'}</div>
      </section>
      <section class="pad"><h2>Project context</h2>
        ${ctx.title || ctx.intro && hero && hero.body !== ctx.intro ? `<div class="ctx-intro muted">${ctx.title ? `<b>${esc(ctx.title)}</b> ` : ''}${hero && hero.body !== ctx.intro ? md(ctx.intro) : ''}</div>` : ''}
        <div class="ctx-cards">${cards.map((c, i) => `<article class="card ctx-card ${c.log ? 'log' : ''}"><h3>${esc(c.title)}</h3>${clamp('s' + i, c.body, c.log ? 240 : 520)}</article>`).join('')}</div>
        <p class="ctx-links"><span class="muted">Context tickets</span> ${(p.context_ticket_ids || []).map(id => ticketLink(id, '#' + id + ' ' + esc(ticket(id)?.title || ''))).join(' · ') || '<span class="muted">none linked</span>'}</p>
        <details class="project-context-editor"><summary>Edit context</summary><textarea rows="14" style="width:100%" data-keep="pcontext:${esc(p.id)}" data-change="projectContext" data-project="${esc(p.id)}">${esc(p.context || '')}</textarea>
          <p class="muted">Markdown. Each <code>##</code> heading becomes a card above; the first one is shown as “where it stands”. Saved when you leave the field; the agent reads and maintains it.</p>
          <label>Context ticket IDs <input data-keep="pcontextids:${esc(p.id)}" data-change="projectContextTickets" data-project="${esc(p.id)}" value="${esc((p.context_ticket_ids || []).join(', '))}" placeholder="3, 12"></label></details>
      </section>
      <section class="pad"><h2>Designs</h2><div class="design-cards">${S.designs.filter(d => d.project === p.id).map(designCard).join('')}
          <button class="design-card new" data-act="newDesign" data-project="${esc(p.id)}">＋ New design</button></div></section>
      <div class="columns">
        <section><h2>Takeaways <span class="count">${s.takeaways.length || ''}</span></h2>${s.takeaways.map(k => `<p class="takeaway-line">💡 ${esc(k.text)} ${ticketLink(k.ticket)}</p>`).join('') || '<p class="empty">No takeaways yet.</p>'}
          <h2>Experiments</h2>${experiments.map(t => `${miniRow(t)}${t.summary ? `<p class="sub">${esc(t.summary)}</p>` : ''}`).join('') || '<p class="empty">No experiments yet.</p>'}
          <h2>Visibility</h2>${shipping.map(miniRow).join('') || '<p class="empty">Nothing shipped or in progress.</p>'}
        </section>
        <section><h2>Everything that happened</h2>
          ${days.map(d => `<div class="day"><time>${fmtDay(d.day)}</time><div>${d.items.map(i =>
            `<button class="event" data-act="open" data-id="${i.ticket}"><b>${esc(kindOf(i.kind).icon)} ${esc(i.title)}</b><span>${esc(i.what)}</span></button>`).join('')}</div></div>`).join('') || '<p class="empty">Nothing yet.</p>'}
        </section>
      </div>`;
  }

  // MARK: Habits

  function renderHabits() {
    main.className = 'page';
    const habits = L.habits(S.tickets, S.today);
    const cols = L.heatmap(S.today, UI.weeks);
    const months = cols.map((col, i) => {
      const first = col.find(Boolean);
      const prev = i ? cols[i - 1].find(Boolean) : null;
      return first && (!prev || prev.slice(5, 7) !== first.slice(5, 7)) ? new Date(first + 'T12:00:00').toLocaleDateString(undefined, { month: 'short' }) : '';
    });
    main.innerHTML = `<header class="page-head"><h1>Habits</h1>
        <p class="muted">Every habit ticket adds a square. Send “meditation 5 min #habit” from anywhere, or check in here.</p></header>
      ${habits.map(h => {
        const max = Math.max(1, ...Object.values(h.days).map(d => d.value || d.count));
        const doneToday = !!h.days[S.today];
        const recent = Object.keys(h.days).sort().reverse().slice(0, 4);
        return `<article class="card habit" style="--h:${L.hue(h.name)}">
          <header><h3>${esc(h.name)}</h3>
            <span class="streak ${h.streak ? 'on' : ''}">🔥 ${h.streak} day streak</span>
            <span class="muted">${h.week}/7 this week · ${h.total} days${h.sum ? ' · ' + h.sum + ' ' + esc(h.unit || '') : ''}</span>
            <span class="spacer"></span>
            <button class="${doneToday ? 'ghost' : 'primary'}" data-act="checkin" data-habit="${esc(h.name)}" ${doneToday ? 'disabled' : ''}>${doneToday ? '✓ Done today' : 'Check in today'}</button></header>
          <div class="heat">
            <div class="heat-months">${months.map(m => `<span>${m}</span>`).join('')}</div>
            <div class="heat-grid">${cols.map(col => `<div>${col.map(day => {
              if (!day) return '<i class="future"></i>';
              const d = h.days[day];
              const tip = fmtDay(day) + (d ? ` · ${d.value ? d.value + ' ' + (h.unit || '') : '✓'}${d.notes.length ? ' · ' + d.notes.join('; ') : ''}` : '');
              return `<i class="l${L.level(d ? (d.value || d.count) : 0, max)} ${day === S.today ? 'today' : ''}" title="${esc(tip)}" ${d ? `data-act="open" data-id="${d.tickets[0]}"` : ''}></i>`;
            }).join('')}</div>`).join('')}</div>
          </div>
          <ul class="recent">${recent.map(day => `<li><time>${fmtDay(day)}</time>${h.days[day].value ? `<b>${h.days[day].value} ${esc(h.unit || '')}</b>` : ''}
            <span>${esc(h.days[day].notes.join('; '))}</span>${h.days[day].tickets.map(id => ticketLink(id)).join(' ')}</li>`).join('')}</ul>
        </article>`;
      }).join('') || '<p class="empty">No habits yet. Send a ticket like “meditation 5 minutes” or “gym 40 min #habit”.</p>'}`;
  }

  // MARK: Plan

  function renderPlan() {
    main.className = 'page';
    const g = L.gantt(S.tickets, S.today);
    const days = Array.from({ length: g.days }, (_, i) => L.addDays(g.start, i));
    const todoKinds = new Set(S.structure.kinds.filter(k => k.view === 'todo').map(k => k.id));
    const todos = visible().filter(t => t.status !== 'closed' && (todoKinds.has(t.kind) || (t.due && !t.start)));
    const buckets = { overdue: 'Overdue', today: 'Today', week: 'Next 7 days', later: 'Later', someday: 'No date' };
    main.innerHTML = `<header class="page-head"><h1>Plan</h1>
        <p class="muted">Plans span days and get a bar; todos take hours and get a deadline.</p></header>
      <article class="card gantt-card">
        ${g.bars.length ? `<div class="gantt" style="--days:${g.days}" data-scroll="gantt">
          <div class="g-row g-head"><div class="g-label"></div><div class="g-track">
            ${days.map((d, i) => `<span class="${i === g.today ? 'today' : ''} ${[0, 6].includes(L.weekday(d)) ? 'weekend' : ''}">${d.slice(8) === '01' || i === 0 ? `<em>${new Date(d + 'T12:00:00').toLocaleDateString(undefined, { month: 'short' })}</em>` : ''}${+d.slice(8)}</span>`).join('')}</div></div>
          ${g.bars.map(b => `<div class="g-row"><button class="g-label" data-act="open" data-id="${b.ticket.id}">${statusDot(b.ticket)}<span>${esc(b.ticket.title)}</span></button>
            <div class="g-track">${days.map((d, i) => `<span class="${i === g.today ? 'today' : ''} ${[0, 6].includes(L.weekday(d)) ? 'weekend' : ''}"></span>`).join('')}
              <button class="g-bar ${b.ticket.status} ${b.late ? 'late' : ''}" style="--from:${b.from};--len:${b.length};--h:${L.hue(b.ticket.project || b.ticket.title)}" data-act="open" data-id="${b.ticket.id}"
                title="${fmtDay(b.ticket.start)} → ${fmtDay(b.ticket.due)}">${esc(b.ticket.project ? projectOf(b.ticket.project).name : '')}${b.late ? ' · late' : ''}</button></div></div>`).join('')}
        </div>` : '<p class="empty">No plans yet. Send a ticket like “Nov 12–15: finish cs646 hw2”, or set Start and Due on any ticket.</p>'}
      </article>
      <h2 class="pad">Todos</h2>
      <div class="todo-cols">${Object.entries(buckets).map(([key, label]) => {
        const items = todos.filter(t => L.dueBucket(t.due, S.today) === key).sort((a, b) => (a.due || '').localeCompare(b.due || ''));
        if (!items.length && (key === 'overdue' || key === 'today')) return '';
        return `<section class="todo-col ${key}"><h3>${label} <span class="count">${items.length || ''}</span></h3>
          ${items.map(t => `<div class="todo"><button class="check" data-act="status" data-id="${t.id}" data-status="closed" title="Mark done"></button>
            <button class="todo-main" data-act="open" data-id="${t.id}"><span>${esc(t.title)}</span>
              <span class="row-meta">${t.project ? `<span class="chip project" style="--h:${L.hue(t.project)}">${esc(projectOf(t.project).name)}</span>` : ''}${t.due ? `<span class="chip due ${key}">${fmtDay(t.due)}</span>` : ''}</span></button></div>`).join('') || '<p class="empty">—</p>'}
        </section>`;
      }).join('')}</div>`;
  }

  // MARK: Library

  function renderLibrary() {
    main.className = 'page';
    const byView = view => { const ids = new Set(S.structure.kinds.filter(k => k.view === view).map(k => k.id)); return visible().filter(t => ids.has(t.kind)); };
    const principles = byView('principle'), resources = byView('resource');
    const answered = visible().filter(t => t.kind === 'question' && t.summary);
    const link = t => { const m = /(https?:\/\/[^\s)>\]]+)/.exec(t.messages.map(x => x.text).join('\n')); return m ? m[1] : null; };
    const byProject = {};
    for (const d of S.designs) (byProject[d.project || ''] = byProject[d.project || ''] || []).push(d);
    const order = Object.keys(byProject).sort((a, b) => (a === '') - (b === '') || projectOf(a).name.localeCompare(projectOf(b).name));
    main.innerHTML = `<header class="page-head"><h1>Library</h1><p class="muted">What you decided, what you kept, what you figured out, what you drew.</p></header>
      <section class="pad designs"><h2>✎ Designs
          <span class="h-actions"><button class="ghost" data-act="newDesign">＋ New design</button>
          <button class="ghost" data-act="importDesigns" title="Copy the .canvas files of a folder (an Obsidian vault folder, say) into the ticket folder. The originals are not changed.">Import a folder…</button>
          <button class="ghost" data-act="revealDesigns" title="Designs are .canvas files; they open in Obsidian too">Show files</button></span></h2>
        <p class="muted">Flowcharts you and the agent both read and edit — the fastest way to agree on how something works.</p>
        <h3 class="design-group">This system <span class="muted">drawn from the current rules</span></h3>
        <div class="design-cards">${SYSTEM_DESIGNS.map(d => designCard({ ...d, system: true })).join('')}</div>
        ${order.map(id => `<h3 class="design-group">${id ? `<button class="chip project" style="--h:${L.hue(id)}" data-act="project" data-project="${esc(id)}">${esc(projectOf(id).name)}</button>` : 'No project'} <span class="muted">${byProject[id].length}</span></h3>
          <div class="design-cards">${byProject[id].slice().sort((a, b) => a.title.localeCompare(b.title)).map(designCard).join('')}</div>`).join('')
          || '<p class="empty">No designs of your own yet. Start one, import a folder of Obsidian canvases, or ask the agent to draw one in a ticket.</p>'}
      </section>
      <div class="columns">
        <section><h2>🧭 Principles</h2>
          ${principles.map((t, i) => `<button class="principle" data-act="open" data-id="${t.id}"><span>${i + 1}</span><p>${esc(t.summary || t.title)}</p></button>`).join('')
            || '<p class="empty">No principles yet. Send one as a ticket; it becomes part of the agent’s instructions.</p>'}
          <h2>❓ Figured out</h2>
          ${answered.map(t => `<button class="event" data-act="open" data-id="${t.id}"><b>${esc(t.title)}</b><span>${esc(t.summary)}</span></button>`).join('') || '<p class="empty">Answered questions appear here.</p>'}
        </section>
        <section><h2>🔖 Resources</h2>
          ${resources.map(t => { const url = link(t); return `<div class="resource"><button class="event" data-act="open" data-id="${t.id}"><b>${esc(t.title)}</b><span>${esc(t.summary || L.snippet(t.messages[0]?.text, 120))}</span>
            <span class="row-meta">${(t.tags || []).map(x => `<span class="chip">#${esc(x)}</span>`).join('')}${t.project ? `<span class="chip project" style="--h:${L.hue(t.project)}">${esc(projectOf(t.project).name)}</span>` : ''}</span></button>
            ${url ? `<button class="link" data-act="url" data-url="${esc(url)}" title="${esc(url)}">Open ↗</button>` : ''}</div>`; }).join('')
            || '<p class="empty">Links, videos, subscriptions and accounts you send are filed here.</p>'}
        </section>
      </div>`;
  }

  // MARK: Designs

  function designCard(d) {
    return `<button class="design-card ${d.system ? 'system' : ''}" data-act="design" data-design="${esc(d.id)}">
      <b>${d.system ? '⚙︎ ' : ''}${esc(d.title)}</b>
      <span>${esc(d.summary || (d.system ? '' : 'No description yet.'))}</span>
      ${d.updated ? `<time>${L.ago(d.updated)}</time>` : ''}</button>`;
  }

  const assetURL = path => 'tkfile://d/' + String(path).split('/').map(encodeURIComponent).join('/');
  const boardOptions = readOnly => ({ readOnly, render: md, assetURL,
    onChange: () => { if (!board || readOnly) return; clearTimeout(board.timer); board.timer = setTimeout(saveBoard, 500); },
    onSelect: updateBoardBar, onView: updateBoardBar });

  function saveBoard() {
    if (!board || !board.dirtyOK) return;
    clearTimeout(board.timer);
    board.timer = null;
    post({ type: 'saveDesign', id: board.id, canvas: board.api.canvas });
  }

  function closeBoard() {
    if (!board) return;
    if (board.api) board.api.flush();
    if (board.timer) saveBoard();
    if (board.api) board.api.destroy();
    board = null;
  }

  function updateBoardBar() {
    const bar = document.getElementById('board-bar');
    if (!bar || !board || !board.api) return;
    const picked = board.api.selection();
    bar.querySelectorAll('[data-needs-selection]').forEach(el => { el.disabled = !picked; });
    bar.querySelectorAll('[data-color]').forEach(el => el.classList.toggle('on', !!picked && (picked.color || '') === el.dataset.color));
    const zoom = bar.querySelector('.zoom');
    if (zoom) zoom.textContent = Math.round(board.api.zoom() * 100) + '%';
  }

  function mountBoard(canvas, readOnly) {
    const host = document.getElementById('board');
    if (!host || !board) return;
    board.api = TKCanvas.mount(host, canvas, boardOptions(readOnly));
    board.dirtyOK = !readOnly;
    updateBoardBar();
    // Read links, formulas and code inside cards the way a ticket shows them.
    host.querySelectorAll('.md pre code').forEach(code => { try { hljs.highlightElement(code); } catch (e) {} });
  }

  function renderDesign() {
    const system = SYSTEM_DESIGNS.find(d => d.id === UI.design);
    const d = system || S.designs.find(x => x.id === UI.design);
    if (!d) { UI.design = null; return renderLibrary(); }
    // The same design is already on screen: leave the canvas alone (re-rendering would drop what is being edited).
    if (board && board.id === d.id && document.getElementById('board')) return;
    closeBoard();
    main.className = 'design';
    board = { id: d.id, api: null, timer: null };
    const tools = system ? `<button class="primary" data-act="copyDesign" title="Make an editable copy in your designs">Save a copy to edit</button>` : `
      <button class="ghost" data-act="boardAdd" data-kind="text" title="Add a card (or double-click empty space)">＋ Card</button>
      <button class="ghost" data-act="boardAdd" data-kind="group" title="Add a box to group cards">＋ Group</button>
      <span class="swatches" title="Colour of the selected card or arrow">${['', '1', '2', '3', '4', '5', '6'].map(c => `<button data-act="boardColor" data-color="${c}" data-needs-selection style="--c:${TKCanvas.colorOf(c) || 'var(--faint)'}"></button>`).join('')}</span>
      <button class="ghost" data-act="boardRemove" data-needs-selection title="Delete what is selected (⌫)">Delete</button>
      <button class="ghost" data-act="boardUndo" title="Undo (⌘Z)">Undo</button>`;
    main.innerHTML = `<header class="design-head">
        <div class="design-row">
          <button class="link" data-act="design" data-design="">← Library</button>
          ${system ? `<h1>${esc(d.title)}</h1>` : `<input class="title" data-change="designTitle" data-design="${esc(d.id)}" value="${esc(d.title)}" title="Rename">`}
          ${system ? '' : `<label class="muted">Project <select data-change="designProject" data-design="${esc(d.id)}"><option value="">none</option>${S.structure.projects.map(p => `<option value="${esc(p.id)}" ${p.id === d.project ? 'selected' : ''}>${esc(p.name)}</option>`).join('')}</select></label>
            <button class="ghost" data-act="revealDesign" data-design="${esc(d.id)}" title="Show the .canvas file in Finder (it opens in Obsidian too)">File</button>
            <button class="ghost danger" data-act="deleteDesign" data-design="${esc(d.id)}">Delete</button>`}
        </div>
        ${system ? `<p class="muted">${esc(d.summary)} Generated from the live rules, so it is always current; drag to pan, pinch or ⌘-scroll to zoom.</p>`
          : `<input class="summary-input" data-change="designSummary" data-design="${esc(d.id)}" value="${esc(d.summary || '')}" placeholder="One line: what this design shows (the agent reads this to decide when to open it)">`}
        <div class="design-row" id="board-bar">${tools}<span class="spacer"></span>
          ${system ? '' : '<span class="muted hint-line">Double-click: add or edit · drag a dot on a card’s edge: connect · ⌫ delete</span>'}
          <button class="ghost" data-act="boardZoom" data-factor="0.8" title="Zoom out">−</button><span class="zoom muted">100%</span>
          <button class="ghost" data-act="boardZoom" data-factor="1.25" title="Zoom in">＋</button>
          <button class="ghost" data-act="boardFit" title="Show everything">Fit</button></div>
      </header>
      <div id="board"></div>`;
    if (system) mountBoard(system.build(), true);
    else post({ type: 'loadDesign', id: d.id });
  }

  // MARK: Tags

  function renderTags() {
    main.className = 'page';
    const rows = L.tagTable(S.tickets, S.structure);
    const loose = rows.filter(r => !r.defined), empty = rows.filter(r => r.defined && !r.meaning).length;
    const top = rows.filter(r => r.defined && r.depth <= 2).length;
    const counts = {};
    for (const t of visible()) { counts['k:' + t.kind] = (counts['k:' + t.kind] || 0) + 1; if (t.project) counts['p:' + t.project] = (counts['p:' + t.project] || 0) + 1; }
    const targets = rows.filter(r => r.defined && !r.legacy);
    const line = r => `<div class="tag-row ${r.defined ? (r.meaning ? '' : 'loose') : 'loose'} ${r.legacy ? 'legacy' : ''} d${Math.min(r.depth, 4)}">
        <code title="#${esc(r.id)}" style="--d:${r.defined ? r.depth - 1 : 0}">${r.defined && r.depth > 1 ? '<i>' + esc(r.id.slice(0, r.id.length - r.name.length)) + '</i>' : '#'}${esc(r.defined ? r.name : r.id)}</code>
        <button class="link" data-act="tagTickets" data-tag="${esc(r.id)}" title="Show these tickets">${r.count || ''}</button>
        <input data-keep="tm:${esc(r.id)}" data-change="tagMeaning" data-tag="${esc(r.id)}" value="${esc(r.meaning)}" title="${esc(r.meaning)}" placeholder="${r.defined ? 'what do these tickets have in common?' : 'not in the vocabulary — give it a meaning, or merge it into a tag →'}">
        <input data-keep="ta:${esc(r.id)}" data-change="tagAction" data-tag="${esc(r.id)}" value="${esc(r.action)}" title="${esc(r.action)}" placeholder="what happens because of it?">
        <select data-change="tagMerge" data-tag="${esc(r.id)}" title="Replace this tag with another on every ticket"><option value="">—</option>${targets.filter(o => o.id !== r.id).map(o => `<option value="${esc(o.id)}">${esc(o.id)}</option>`).join('')}</select>
        <button class="ghost danger" data-act="deleteTag" data-tag="${esc(r.id)}" data-count="${r.count}" title="Delete this tag (and anything below it) everywhere">×</button>
      </div>`;
    const head = '<div class="tag-row head"><span>Tag</span><span>Tickets</span><span>Meaning</span><span>Action</span><span>Merge into</span><span></span></div>';
    main.innerHTML = `<header class="page-head"><h1>Tags</h1>
        <p class="muted">The common language of the ticket system: a layered vocabulary kept as plain files in the <button class="link" data-act="revealTags" title="${esc(S.tagRules.folder)}">tags folder</button>.
          A tag is a path — <b>purpose / field / concept</b> — and every tag carries a <b>meaning</b> and an <b>action</b>. The index (depth 1–2) stays small; detail goes deeper.
          A ticket has one kind, at most one project, and any number of tags. The agent may only use tags defined here.</p>
        <div class="bar"><button class="primary" data-act="tidyTags" title="Opens a ticket asking the agent to file loose tags under the vocabulary, merge near-duplicates and delete empty ones">✦ Ask the agent to tidy up</button>
          <button class="ghost" data-act="design" data-design="sys:categories">See how a capture is categorized</button>
          <span class="chip ${top > S.tagRules.indexMax ? 'due overdue' : ''}" title="Depth 1–2 tags live in references/index.md, the only file the agent is shown in full">index ${top}/${S.tagRules.indexMax}</span>
          ${S.tagRules.map ? '<span class="chip" title="tags/references/map.md is sent to the agent with every ticket">classification map ✓</span>' : ''}
          ${loose.length ? `<span class="chip due today">${loose.length} loose</span>` : ''}${empty ? `<span class="chip due today">${empty} need a meaning</span>` : ''}</div>
        ${(S.tagRules.problems || []).length ? `<p class="banner">⚠︎ ${S.tagRules.problems.slice(0, 4).map(x => md(x).replace(/<\/?p>/g, '')).join(' · ')}${S.tagRules.problems.length > 4 ? ` · +${S.tagRules.problems.length - 4} more` : ''}</p>` : ''}</header>
      <section class="pad tag-page">
        ${loose.length ? `<h2>Loose tags <span class="count">${loose.length} · on tickets, not in the vocabulary</span></h2>
          <p class="muted">File each one: pick <b>Merge into</b> to replace it with a tag from the vocabulary, give it a meaning to keep it as its own top-level tag, or delete it.</p>
          <div class="tag-table">${head}${loose.map(line).join('')}</div>` : ''}
        <h2>Vocabulary <span class="count">${rows.length - loose.length}</span></h2>
        <div class="tag-table">${head}${rows.filter(r => r.defined).map(line).join('') || '<p class="empty">No tags yet. Define one below, or copy a vocabulary into the tags folder.</p>'}</div>
        <form class="inline tag-new" data-submit="defineTag">
          <input name="text" data-keep="newtag" placeholder="＋ parent/new-tag">
          <input name="meaning" data-keep="newtag-m" placeholder="meaning">
          <input name="action" data-keep="newtag-a" placeholder="action">
          <button class="primary">Define tag</button></form>
        <h2>Kinds — what a ticket is <span class="count">exactly one</span></h2>
        <p class="muted">A kind is the tag that decides where a ticket shows up and which rule the agent follows. <button class="link" data-act="agentKinds">Edit kinds and rules</button></p>
        <div class="tag-cloud">${S.structure.kinds.map(k => `<span class="chip kind" title="${esc(k.description)}&#10;→ ${esc(k.rule)}">${esc(k.icon)} ${esc(k.label)} <code>#${esc(k.id)}</code> <b>${counts['k:' + k.id] || 0}</b></span>`).join('')}</div>
        <h2>Projects — where it belongs <span class="count">at most one</span></h2>
        <div class="tag-cloud">${S.structure.projects.map(p => `<button class="chip project" style="--h:${L.hue(p.id)}" data-act="project" data-project="${esc(p.id)}" title="${esc(p.type)}${p.note ? ' · ' + esc(p.note) : ''}">${esc(p.name)} <b>${counts['p:' + p.id] || 0}</b></button>`).join('') || '<span class="muted">No projects yet.</span>'}</div>
      </section>`;
  }

  // MARK: Agent

  function renderAgent() {
    main.className = 'page';
    const tabs = [['instructions', 'Instructions'], ['tools', 'Tools'], ['kinds', 'Kinds & rules'], ['corrections', `Corrections ${S.corrections.length || ''}`], ['updates', `App updates ${S.selfUpdate.records.length || ''}`], ['decisions', 'Decision log'], ['prompt', 'Full prompt']];
    let body = '';
    if (UI.agentTab === 'instructions') {
      body = `<p class="muted">Standing instructions, sent with every ticket. Keep them short — rules for one kind of ticket belong under Kinds & rules.</p>
        <textarea class="code" id="instructions" data-keep="instructions" rows="12">${esc(S.instructions)}</textarea>
        <div class="bar"><button class="primary" data-act="saveInstructions">Save</button>
          <button class="ghost" data-act="resetInstructions" title="Restore the built-in instructions">Reset</button>
          <span class="muted">Stored in agent/instructions.md in the ticket folder.</span></div>`;
    } else if (UI.agentTab === 'tools') {
      const areas = [['tickets', 'Tickets'], ['projects', 'Projects'], ['tags', 'Tags and kinds'], ['designs', 'Designs']];
      body = `<p class="muted">What the agent may do. On every turn it sets the fields of the ticket it is answering; beyond that, these tools let it organize the rest — they go in the <code>actions</code> list of its reply, and every use is recorded in the Decision log. Reading files, searching the web and running code are governed by its access (${esc(S.settings.accessNote || '')}).
          <button class="link" data-act="design" data-design="sys:system">See the whole system as a flowchart</button></p>
        <div class="tool-row head"><code>this ticket</code><p>title · summary · kind · project · related projects · tags · status · start / due · log (habit entries) · takeaways</p></div>
        ${areas.map(([id, label]) => `<h2>${label}</h2>${S.tools.filter(t => t.area === id).map(t => `<div class="tool-row"><code>${esc(t.name)}</code>
          <p>${esc(t.what)}<span class="args">${esc(t.arguments)}</span></p></div>`).join('')}`).join('')}`;
    } else if (UI.agentTab === 'kinds') {
      body = `<p class="muted">What a ticket can be, how the agent recognizes it, and what it does. The list grows: the agent proposes a kind when nothing fits. <b>View</b> decides where a kind shows up.</p>
        <div class="kinds-table">${S.structure.kinds.map((k, i) => `<div class="kind-row" data-kind-row="${i}">
          <input class="icon" data-keep="k-icon:${i}" name="icon" value="${esc(k.icon)}" title="Icon">
          <div class="kind-names"><input data-keep="k-label:${i}" name="label" value="${esc(k.label)}" title="Name">
            <code title="id — use it as #${esc(k.id)}">#${esc(k.id)}</code>
            <select name="view" title="View">${['thread', 'todo', 'plan', 'habit', 'resource', 'principle'].map(v => `<option ${v === k.view ? 'selected' : ''}>${v}</option>`).join('')}</select></div>
          <textarea data-keep="k-desc:${i}" name="description" rows="2" title="What it looks like">${esc(k.description)}</textarea>
          <textarea data-keep="k-rule:${i}" name="rule" rows="2" title="What the agent does">${esc(k.rule)}</textarea>
          ${k.id === 'misc' ? '<span></span>' : `<button class="ghost danger" data-act="removeKind" data-index="${i}" title="Remove this kind (its tickets become Uncategorized)">×</button>`}
        </div>`).join('')}</div>
        <div class="bar"><button class="primary" data-act="saveKinds">Save kinds</button>
          <form class="inline slim" data-submit="addKind"><input name="text" data-keep="newkind" placeholder="＋ new kind name"></form></div>`;
    } else if (UI.agentTab === 'corrections') {
      body = `<p class="muted">What you told the agent it got wrong. Every correction is part of its prompt from then on. Changing a ticket’s kind or project by hand logs one automatically.</p>
        <form class="inline" data-submit="correction"><input name="text" data-keep="correction" placeholder="Add a general correction…"><button class="primary">Add</button></form>
        ${S.corrections.slice().reverse().map(c => `<div class="log-row"><time>${fmtTime(c.at)}</time>${c.ticket != null ? ticketLink(c.ticket) : '<span></span>'}
          <p>${esc(c.text)}</p><button class="ghost danger" data-act="removeCorrection" data-at="${esc(c.at)}" data-text="${esc(c.text)}" title="Remove">×</button></div>`).join('') || '<p class="empty">No corrections yet.</p>'}`;
    } else if (UI.agentTab === 'updates') {
      const su = S.selfUpdate;
      const label = { pending: 'Not rebuilt yet', building: 'Building…', ok: 'Running', build_failed: 'Build failed', rolled_back: 'Rolled back automatically', reverted: 'Rolled back' };
      body = `<p class="muted">When the agent changes Quick Capture's own source, each run is kept here. Before every run the project is snapshotted into git, so any of them can be undone — your uncommitted work included. A rebuild backs up the installed app first and restores it by itself if the new version doesn't start.</p>
        ${su.enabled ? (su.problem ? `<p class="banner">⚠︎ ${esc(su.problem)} <button class="link" data-act="selfFolder">Choose folder…</button></p>`
            : `<p class="muted">Project: <code>${esc(su.folder)}</code> <button class="link" data-act="selfFolder">Change…</button></p>`)
          : `<p class="banner">Self-update is off. <button class="link" data-act="settings">Turn it on in Settings…</button></p>`}
        ${su.records.map(r => `<div class="update ${esc(r.result)}"><header>${ticketLink(r.ticket, '#' + r.ticket + (ticket(r.ticket) ? ' ' + esc(ticket(r.ticket).title) : ''))}
            <time>${fmtTime(r.at)}</time><span class="status-pill ${r.result === 'ok' ? 'closed' : r.result === 'building' ? 'needs_agent' : r.result === 'pending' ? 'waiting_human' : ''}">${esc(label[r.result] || r.result)}</span>
            <span class="spacer"></span>
            ${r.result === 'pending' || r.result === 'build_failed' ? `<button class="primary" data-act="selfRebuild" data-record="${esc(r.id)}" ${su.busy || su.problem ? 'disabled' : ''}>${r.result === 'pending' ? 'Rebuild & restart' : 'Try again'}</button>` : ''}
            ${['pending', 'build_failed', 'ok'].includes(r.result) ? `<button class="ghost danger" data-act="selfRollback" data-record="${esc(r.id)}" ${su.busy ? 'disabled' : ''}>${r.result === 'ok' ? 'Roll back…' : 'Discard changes…'}</button>` : ''}</header>
          <p class="files">${r.files.slice(0, 10).map(f => `<span class="chip">${esc(f)}</span>`).join('')}${r.files.length > 10 ? `<span class="muted">+${r.files.length - 10} more</span>` : ''}</p>
          ${r.note ? `<pre class="prompt note">${esc(r.note)}</pre>` : ''}
          <p class="muted refs">rollback point <code>${esc(r.before.slice(0, 8))}</code> → <code>${esc(r.after.slice(0, 8))}</code></p></div>`).join('') || '<p class="empty">No changes to the app yet.</p>'}`;
    } else if (UI.agentTab === 'decisions') {
      body = `<p class="muted">Everything the agent changed on a ticket, and why. Spot something wrong? Open the ticket and press <b>Correct agent</b>.</p>
        ${S.decisions.slice().reverse().map(d => `<div class="log-row"><time>${fmtTime(d.at)}</time>${ticketLink(d.ticket, '#' + d.ticket + (ticket(d.ticket) ? ' ' + esc(ticket(d.ticket).title) : ''))}
          <p>${(d.changes || []).map(c => `<span class="chip">${esc(c)}</span>`).join(' ')}${(d.reasons || []).map(r => `<span class="reason">${esc(r)}</span>`).join('')}</p>
          <span class="muted">${esc(d.agent)}</span></div>`).join('') || '<p class="empty">No decisions yet.</p>'}`;
    } else {
      body = `<p class="muted">Exactly what the agent is told before it sees a ticket: instructions, kinds, projects, principles and corrections — followed by the other tickets, the ticket itself, and the reply format.</p>
        <pre class="prompt">${esc(S.prompt)}\n# Reply format\n${esc(S.contract)}</pre>`;
    }
    main.innerHTML = `<header class="page-head"><h1>Agent</h1>
        <p class="muted"><b>${esc(S.settings.agent || '')}</b> · ${esc(S.settings.accessNote || '')}
          <button class="link" data-act="settings">Change…</button> · <button class="link" data-act="revealRoot" title="${esc(S.settings.folder || '')}">Ticket folder</button></p>
        <div class="tabs">${tabs.map(([id, label]) => `<button class="pill ${UI.agentTab === id ? 'on' : ''}" data-act="agentTab" data-tab="${id}">${label}</button>`).join('')}</div></header>
      <div class="agent-body">${body}</div>`;
  }

  // MARK: Render, keeping what the user is typing

  function render() {
    if (UI.view === 'library' && UI.design) { renderNav(); return renderDesign(); }
    closeBoard();
    const keep = {};
    document.querySelectorAll('[data-keep]').forEach(el => {
      keep[el.dataset.keep] = { value: el.value, focus: el === document.activeElement, start: el.selectionStart, end: el.selectionEnd, dirty: el.value !== el.defaultValue };
    });
    const scroll = {};
    document.querySelectorAll('[data-scroll]').forEach(el => { scroll[el.dataset.scroll] = { top: el.scrollTop, left: el.scrollLeft, bottom: el.scrollHeight - el.scrollTop - el.clientHeight < 60 }; });
    const openDetails = new Set([...document.querySelectorAll('details[open]')].map(d => d.className + ':' + [...document.querySelectorAll('details.' + d.className.split(' ')[0])].indexOf(d)));

    renderNav();
    ({ inbox: renderInbox, projects: renderProjects, habits: renderHabits, plan: renderPlan, library: renderLibrary, tags: renderTags, agent: renderAgent }[UI.view] || renderInbox)();

    const where = UI.view + ':' + (UI.project || '') + ':' + UI.agentTab;
    if (where !== render.where && UI.view !== 'inbox') main.scrollTop = 0;
    render.where = where;
    document.querySelectorAll('[data-keep]').forEach(el => {
      const k = keep[el.dataset.keep];
      if (!k) return;
      if (k.dirty || k.focus) el.value = k.value;
      if (k.focus) { el.focus(); try { el.setSelectionRange(k.start, k.end); } catch (e) { /* not a text field */ } }
    });
    document.querySelectorAll('[data-scroll]').forEach(el => {
      const s = scroll[el.dataset.scroll];
      if (s) { el.scrollTop = s.bottom && el.dataset.scroll.startsWith('thread:') ? el.scrollHeight : s.top; el.scrollLeft = s.left; }
      // A ticket just opened: short ones from the top, long conversations at the latest message.
      else if (el.dataset.scroll.startsWith('thread:')) el.scrollTop = el.querySelectorAll('.msg').length > 2 ? el.scrollHeight : 0;
      else if (el.dataset.scroll === 'gantt') el.scrollLeft = 0;
    });
    document.querySelectorAll('details').forEach(d => {
      const key = d.className + ':' + [...document.querySelectorAll('details.' + d.className.split(' ')[0])].indexOf(d);
      if (openDetails.has(key)) d.open = true;
    });
    if (typeof TKDiagrams !== 'undefined') TKDiagrams.render(main, window.mermaid,
      svg => DOMPurify.sanitize(svg, { USE_PROFILES: { svg: true, svgFilters: true } }));
    main.querySelectorAll('.md pre code:not(.language-mermaid):not([data-hl])').forEach(code => { try { hljs.highlightElement(code); } catch (e) {} code.dataset.hl = '1'; });
    const auto = main.querySelector('[autofocus]');
    if (auto && document.activeElement !== auto && !Object.values(keep).some(k => k.focus)) auto.focus();
  }

  // MARK: Actions

  function open(id) {
    const t = ticket(id);
    if (!t) return;
    UI.view = 'inbox';
    UI.design = null;
    UI.selected = id;
    UI.panel = null;
    const filter = FILTERS.find(f => f[0] === UI.filter);
    if (t.merged_into != null || !filter[2](t)) UI.filter = t.status === 'closed' ? 'closed' : 'open';
    UI.kind = '';
    render();
  }

  function saveStructure(change) {
    const next = JSON.parse(JSON.stringify(S.structure));
    change(next);
    S.structure = next;
    post({ type: 'structure', structure: next });
    render();
  }

  function collectKinds() {
    return [...document.querySelectorAll('[data-kind-row]')].map(row => {
      const k = S.structure.kinds[+row.dataset.kindRow];
      const field = name => row.querySelector(`[name="${name}"]`).value.trim();
      return { ...k, icon: field('icon') || '🏷', label: field('label') || k.id, view: field('view'), description: field('description'), rule: field('rule') };
    });
  }

  function sendReply(id, type) {
    const box = 'reply:' + id;
    const area = document.querySelector(`textarea[data-box="${box}"]`);
    const text = area ? area.value.trim() : '';
    const staged = (UI.staged[box] || []).map(s => s.name);
    if (!text && !staged.length) return;
    post({ type, id, text, staged, ...pickFields() });
    if (area) { area.value = ''; area.defaultValue = ''; }
    UI.staged[box] = [];
  }

  const actions = {
    compose: () => post({ type: 'compose' }),
    settings: () => post({ type: 'openSettings' }),
    revealRoot: () => post({ type: 'reveal' }),
    filter: d => { UI.view = 'inbox'; UI.filter = d.filter; UI.kind = ''; UI.design = null; },
    view: d => { UI.view = d.view; UI.design = null; if (d.view === 'projects') UI.project = null; },
    design: d => { UI.view = 'library'; UI.design = d.design || null; },
    newDesign: d => { post({ type: 'saveDesign', new: true, open: true, title: 'Untitled design', project: d.project || '', canvas: { nodes: [], edges: [] } }); return false; },
    copyDesign: () => { const d = SYSTEM_DESIGNS.find(x => x.id === UI.design); if (d) post({ type: 'saveDesign', new: true, open: true, title: d.title, summary: d.summary, canvas: d.build() }); return false; },
    importDesigns: () => { post({ type: 'importDesigns' }); return false; },
    revealDesigns: () => { post({ type: 'revealDesign' }); return false; },
    revealDesign: d => { post({ type: 'revealDesign', id: d.design }); return false; },
    deleteDesign: d => { const x = S.designs.find(o => o.id === d.design); if (!confirm(`Delete the design “${x ? x.title : d.design}”? Its file moves to the trash folder inside the ticket folder.`)) return false; if (board) { clearTimeout(board.timer); board.timer = null; } post({ type: 'deleteDesign', id: d.design }); UI.design = null; },
    boardAdd: d => { if (board && board.api) board.api.add(d.kind); return false; },
    boardColor: d => { if (board && board.api) board.api.setColor(d.color); return false; },
    boardRemove: () => { if (board && board.api) board.api.remove(); return false; },
    boardUndo: () => { if (board && board.api) board.api.undo(); return false; },
    boardZoom: d => { if (board && board.api) board.api.zoomBy(+d.factor); return false; },
    boardFit: () => { if (board && board.api) board.api.fit(); return false; },
    removeTag: d => { const t = ticket(+d.id); if (t) post({ type: 'edit', id: t.id, fields: { tags: (t.tags || []).filter(x => x !== d.tag) } }); return false; },
    deleteTag: d => { if (confirm(`Delete #${d.tag}? It is removed from ${d.count} ticket${d.count === '1' ? '' : 's'}; the tickets themselves stay.`)) post({ type: 'deleteTag', id: d.tag }); return false; },
    tagTickets: d => { UI.view = 'inbox'; UI.filter = 'open'; UI.kind = ''; UI.query = '#' + d.tag; },
    tidyTags: () => { post({ type: 'create', text: 'Tidy the tags. Read tags/SKILL.md and the map first. For every loose tag on a ticket: merge it into the vocabulary tag that already says it (merge_tags), or define it at the right depth under an existing parent with a meaning and an action (define_tag) when two or more tickets need it, or delete it (delete_tag) when it only repeats the kind, the project or the title. Then give every open ticket exactly one top-level purpose. Reply with a table of what you changed and what you were unsure about. #todo', staged: [] }); toast('Ticket sent — the agent is tidying the tags.'); return false; },
    agentKinds: () => { UI.view = 'agent'; UI.agentTab = 'kinds'; },
    ctxToggle: d => { UI.ctxOpen[d.key] = !UI.ctxOpen[d.key]; },
    revealTags: () => { post({ type: 'revealTags' }); return false; },
    kind: d => { UI.kind = d.kind; },
    open: d => { open(+d.id); return false; },
    project: d => { UI.view = 'projects'; UI.design = null; UI.project = d.project || null; },
    agentTab: d => { UI.agentTab = d.tab; },
    agentUpdates: () => { UI.view = 'agent'; UI.design = null; UI.agentTab = 'updates'; },
    panel: d => { const same = UI.panel && UI.panel.id === +d.id && UI.panel.type === d.panel; UI.panel = same ? null : { id: +d.id, type: d.panel }; },
    status: d => post({ type: 'status', id: +d.id, status: d.status }),
    run: d => post({ type: 'run', id: +d.id, ...pickFields() }),
    stop: d => post({ type: 'stop', id: +d.id }),
    reveal: d => post({ type: 'reveal', id: +d.id }),
    selfRebuild: d => post({ type: 'selfRebuild', record: d.record }),
    selfRollback: d => post({ type: 'selfRollback', record: d.record }),
    selfFolder: () => post({ type: 'selfFolder' }),
    reply: d => sendReply(+d.id, 'reply'),
    note: d => sendReply(+d.id, 'note'),
    screenshot: d => post({ type: 'screenshot', box: d.box }),
    pickFiles: d => post({ type: 'pickFiles', box: d.box }),
    unstage: d => { const [gone] = (UI.staged[d.box] || []).splice(+d.index, 1); if (gone) post({ type: 'unstage', name: gone.name }); },
    attachment: d => post({ type: 'openAttachment', id: +d.id, name: d.name }),
    url: d => post({ type: 'openURL', url: d.url }),
    removeTakeaway: d => post({ type: 'removeTakeaway', id: +d.id, text: d.text }),
    removeLog: d => post({ type: 'removeLog', id: +d.id, date: d.date, name: d.name }),
    removeCorrection: d => post({ type: 'removeCorrection', at: d.at, text: d.text }),
    delete: d => { const t = ticket(+d.id); if (confirm(`Delete ticket #${d.id} “${t ? t.title : ''}”? Its file moves to the trash folder inside the ticket folder.`)) { post({ type: 'delete', id: +d.id }); UI.selected = null; } },
    unmerge: d => { if (confirm('Unmerge? The merged ticket is removed (anything written on it since the merge goes to the trash folder) and the originals come back.')) { post({ type: 'unmerge', id: +d.id }); UI.selected = null; } },
    mergeAdd: d => { const input = document.querySelector(`[data-keep="merge:${d.id}"]`); if (input && !input.value.split(/[\s,#]+/).includes(d.other)) input.value = (input.value + ' ' + d.other).trim(); return false; },
    important: d => saveStructure(s => { const p = s.projects.find(p => p.id === d.project); if (p) p.important = !p.important; }),
    shipTicket: d => post({ type: 'create', text: `Make ${projectOf(d.project).name} visible: decide what to ship (paper, video, post, release) and what is left. #shipping #${d.project}`, staged: [] }),
    checkin: d => { post({ type: 'create', text: `${d.habit} done #habit`, staged: [] }); toast('Checked in — the agent is logging it.'); },
    saveInstructions: () => { post({ type: 'instructions', text: document.getElementById('instructions').value }); document.getElementById('instructions').defaultValue = document.getElementById('instructions').value; toast('Instructions saved.'); },
    resetInstructions: () => { if (confirm('Replace your instructions with the built-in ones?')) { const el = document.getElementById('instructions'); el.value = ''; el.defaultValue = ''; post({ type: 'instructions', text: '' }); } },
    saveKinds: () => { const kinds = collectKinds(); document.querySelectorAll('[data-kind-row] [data-keep]').forEach(el => { el.defaultValue = el.value; }); saveStructure(s => { s.kinds = kinds; }); toast('Kinds saved.'); },
    removeKind: d => { const kinds = collectKinds(); const [gone] = kinds.splice(+d.index, 1); if (gone && confirm(`Remove the kind “${gone.label}”? Tickets of this kind keep their content and show as Uncategorized.`)) saveStructure(s => { s.kinds = kinds; }); },
  };

  const submits = {
    correction: (d, text) => { post({ type: 'correction', id: d.id ? +d.id : undefined, text }); UI.panel = null; toast('Correction logged — the agent will see it from now on.'); },
    takeaway: (d, text) => post({ type: 'takeaway', id: +d.id, text }),
    merge: (d, text, form) => {
      const ids = form.ids.value.split(/[\s,#]+/).map(Number).filter(n => n && ticket(n));
      if (!ids.length) return toast('Enter the numbers of the tickets to merge.');
      post({ type: 'merge', ids: [+d.id, ...ids] });
      UI.panel = null;
    },
    addTag: (d, text) => {
      const t = ticket(+d.id);
      const tags = text.split(/[\s,#]+/).filter(Boolean);
      if (t && tags.length) post({ type: 'edit', id: t.id, fields: { tags: [...(t.tags || []), ...tags] } });
    },
    defineTag: (d, text, form) => post({ type: 'defineTag', id: text, meaning: form.meaning.value.trim(), action: form.action.value.trim() }),
    addKind: (d, text) => {
      const id = text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-|-$/g, '');
      if (!id || S.structure.kinds.some(k => k.id === id)) return toast('That kind already exists.');
      const kinds = collectKinds();
      kinds.splice(Math.max(0, kinds.length - 1), 0, { id, label: text, icon: '🏷', view: 'thread', description: '', rule: '' });
      saveStructure(s => { s.kinds = kinds; });
    },
  };

  document.addEventListener('click', e => {
    const el = e.target.closest('[data-act]');
    if (!el || el.disabled) return;
    const act = actions[el.dataset.act];
    if (!act) return;
    e.preventDefault();
    e.stopPropagation();
    if (act(el.dataset) !== false) render();
  });

  document.addEventListener('submit', e => {
    const form = e.target.closest('[data-submit]');
    if (!form) return;
    e.preventDefault();
    const input = form.querySelector('[name="text"]');
    const text = input ? input.value.trim() : '';
    if (input && !text) return;
    submits[form.dataset.submit](form.dataset, text, form);
    form.querySelectorAll('input').forEach(i => { i.value = ''; i.defaultValue = ''; });
    render();
  });

  document.addEventListener('change', e => {
    const pick = e.target.closest('[data-pick]');
    if (pick) {
      UI.pick[pick.dataset.pick] = pick.value;
      if (pick.dataset.pick === 'agent') UI.pick.model = '';  // models belong to one agent
      // An effort level that the newly chosen agent doesn't have goes back to its default.
      const agent = (S.settings.agents || []).find(a => a.id === (UI.pick.agent || S.settings.agentID));
      if (agent && UI.pick.effort && !agent.efforts.includes(UI.pick.effort)) UI.pick.effort = '';
      return render();
    }
    const el = e.target.closest('[data-change]');
    if (!el) return;
    const field = el.dataset.change, value = el.value.trim();
    if (field === 'tagMeaning' || field === 'tagAction') {
      el.defaultValue = el.value;
      return post({ type: 'defineTag', id: el.dataset.tag, [field === 'tagMeaning' ? 'meaning' : 'action']: value });
    }
    if (field === 'tagMerge') {
      if (value && confirm(`Replace #${el.dataset.tag} with #${value} on every ticket? #${el.dataset.tag} disappears.`)) post({ type: 'mergeTags', from: [el.dataset.tag], into: value });
      else el.value = '';
      return;
    }
    if (field === 'designTitle' || field === 'designProject' || field === 'designSummary') {
      if (field === 'designTitle' && !value) return;
      el.defaultValue = el.value;
      return post({ type: 'saveDesign', id: el.dataset.design, [{ designTitle: 'title', designProject: 'project', designSummary: 'summary' }[field]]: value });
    }
    if (field === 'projectType' || field === 'projectNote' || field === 'projectContext' || field === 'projectContextTickets') {
      el.defaultValue = el.value;
      return saveStructure(s => {
        const p = s.projects.find(p => p.id === el.dataset.project);
        if (!p) return;
        if (field === 'projectContextTickets') {
          p.context_ticket_ids = [...new Set(value.split(/[\s,]+/).map(Number).filter(id => S.tickets.some(t => t.id === id)))];
        } else {
          if (field === 'projectType') p.type = value.toLowerCase() || 'personal';
          else p[field === 'projectContext' ? 'context' : 'note'] = value;
        }
      });
    }
    const id = +el.dataset.id;
    const fields = {};
    if (field === 'related_projects') fields.related_projects = value.split(/[\s,]+/).filter(Boolean);
    else if (field === 'tags') fields.tags = value.split(/[\s,#]+/).filter(Boolean);
    else if (field === 'start' || field === 'due' || field === 'due_time') fields[field] = value || null;
    else if (field === 'title' && !value) return;
    else fields[field] = value;
    el.defaultValue = el.value;
    post({ type: 'edit', id, fields });
  });

  document.addEventListener('input', e => {
    const el = e.target.closest('[data-input]');
    if (!el) return;
    UI[el.dataset.input] = el.value;
    render();
  });

  document.addEventListener('keydown', e => {
    const area = e.target.closest && e.target.closest('textarea[data-box]');
    if (area && e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      sendReply(+area.dataset.box.split(':')[1], e.metaKey ? 'reply' : 'note');
      render();
    } else if (e.key === 'n' && e.metaKey) {
      e.preventDefault();
      post({ type: 'compose' });
    } else if (e.key === 'f' && e.metaKey) {
      const search = document.querySelector('[data-keep="search"]');
      if (search) { e.preventDefault(); search.focus(); search.select(); }
    } else if (e.key === 'Enter' && e.target.matches && e.target.matches('input[data-change]')) {
      e.target.blur();
    }
  });

  document.addEventListener('paste', e => {
    const area = e.target.closest && e.target.closest('textarea[data-box]');
    const files = [...(e.clipboardData?.files || [])];
    if (!area || !files.length) return;
    e.preventDefault();
    for (const file of files) {
      const reader = new FileReader();
      reader.onload = () => post({ type: 'stageData', box: area.dataset.box, name: file.name || 'pasted.png', data: String(reader.result).split(',')[1] });
      reader.readAsDataURL(file);
    }
  });

  // MARK: Column widths (the sidebar and the ticket list), remembered between launches

  const WIDTHS = { nav: { min: 150, max: 340, initial: 196 }, list: { min: 240, max: 720, initial: 350 } };
  const store = { get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* private mode */ } } };
  function setWidth(name, px) {
    const w = WIDTHS[name];
    const value = Math.max(w.min, Math.min(w.max, Math.round(px)));
    document.documentElement.style.setProperty('--' + name + '-w', value + 'px');
    return value;
  }
  for (const name of Object.keys(WIDTHS)) { const saved = +store.get('tk-width-' + name); if (saved) setWidth(name, saved); }
  document.addEventListener('pointerdown', e => {
    const handle = e.target.closest && e.target.closest('[data-resize]');
    if (!handle || e.button !== 0) return;
    e.preventDefault();
    const name = handle.dataset.resize, pane = name === 'nav' ? nav : document.querySelector('.list');
    const startX = e.clientX, startW = pane.getBoundingClientRect().width;
    let value = startW;
    document.body.classList.add('resizing');
    const move = ev => { value = setWidth(name, startW + ev.clientX - startX); };
    const up = () => {
      document.removeEventListener('pointermove', move);
      document.removeEventListener('pointerup', up);
      document.body.classList.remove('resizing');
      store.set('tk-width-' + name, String(value));
    };
    document.addEventListener('pointermove', move);
    document.addEventListener('pointerup', up);
  });
  document.addEventListener('dblclick', e => {
    const handle = e.target.closest && e.target.closest('[data-resize]');
    if (!handle) return;
    store.set('tk-width-' + handle.dataset.resize, String(setWidth(handle.dataset.resize, WIDTHS[handle.dataset.resize].initial)));
  });

  window.TK = {
    receive(msg) {
      if (msg.type === 'state') {
        S = { designs: [], tools: [], tagRules: { indexMax: 30, fileMax: 15, folder: '', problems: [], map: false }, ...msg };
        if (!loaded) {
          loaded = true;
          // Start where there is something to do.
          const all = visible();
          UI.filter = all.some(t => t.status === 'waiting_human') ? 'you' : 'open';
        }
        if (UI.selected != null && !ticket(UI.selected)) UI.selected = null;
        render();
      } else if (msg.type === 'busy') {
        S.busy = msg.busy;
        render();
      } else if (msg.type === 'staged') {
        // Files dropped on the window go to the reply box of the open ticket.
        const box = msg.box || (UI.selected != null ? 'reply:' + UI.selected : '');
        if (!box) return toast('Open a ticket first, or use ＋ New ticket.');
        (UI.staged[box] = UI.staged[box] || []).push(...msg.items);
        render();
      } else if (msg.type === 'open') {
        open(msg.id);
      } else if (msg.type === 'design') {
        if (!board || board.id !== msg.id) return;
        if (board.api) board.api.destroy();
        mountBoard(msg.canvas, false);
      } else if (msg.type === 'designRedrawn') {
        // The agent redrew the design that is on screen.
        if (board && board.id === msg.id) { clearTimeout(board.timer); board.timer = null; post({ type: 'loadDesign', id: msg.id }); toast('The agent redrew this design.'); }
      } else if (msg.type === 'openDesign') {
        UI.view = 'library';
        UI.design = msg.id;
        render();
      } else if (msg.type === 'error') {
        toast(msg.message);
      }
    },
    /// For tests and previews.
    ui: UI,
    render,
  };
  render();
  post({ type: 'ready' });
})();
