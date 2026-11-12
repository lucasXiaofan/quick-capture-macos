// Pure helpers for the Tickets pages (no DOM), so tests can run them in Node.
// Everything here turns the flat list of tickets into a view: tickets never store how they are shown.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.TKLogic = api;
})(typeof self !== 'undefined' ? self : globalThis, function () {
  const DAY = 86400000;
  const pad = n => String(n).padStart(2, '0');

  // Days are 'YYYY-MM-DD' strings in local time; arithmetic goes through UTC noon to dodge DST.
  const toDate = day => new Date(Date.UTC(+day.slice(0, 4), +day.slice(5, 7) - 1, +day.slice(8, 10), 12));
  const fromDate = d => d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate());
  const addDays = (day, n) => fromDate(new Date(toDate(day).getTime() + n * DAY));
  const diffDays = (a, b) => Math.round((toDate(b) - toDate(a)) / DAY);
  const weekday = day => toDate(day).getUTCDay();  // 0 = Sunday
  const dayOf = stamp => (stamp || '').slice(0, 10);

  function hashtags(text) {
    const found = [];
    const re = /(?:^|\s)#([\p{L}\p{N}][\p{L}\p{N}_/-]*)/gu;
    let m;
    while ((m = re.exec(text || ''))) {
      const tag = m[1].toLowerCase();
      if (!found.includes(tag)) found.push(tag);
    }
    return found;
  }

  /// The word being typed at the caret if it is a hashtag: { start, query }.
  function tagAtCaret(text, caret) {
    const before = text.slice(0, caret);
    const m = /(^|\s)#([\p{L}\p{N}_/-]*)$/u.exec(before);
    return m ? { start: caret - m[2].length - 1, query: m[2].toLowerCase() } : null;
  }

  const visible = tickets => tickets.filter(t => t.merged_into == null);

  function snippet(text, limit = 140) {
    const flat = (text || '').replace(/```[\s\S]*?```/g, ' ').replace(/[#*_`>\[\]]/g, '').replace(/\s+/g, ' ').trim();
    return flat.length > limit ? flat.slice(0, limit) + '…' : flat;
  }

  function ago(stamp, now = Date.now()) {
    const t = new Date(stamp).getTime();
    if (!t) return '';
    const mins = Math.floor((now - t) / 60000);
    if (mins < 1) return 'now';
    if (mins < 60) return mins + 'm';
    if (mins < 60 * 24) return Math.floor(mins / 60) + 'h';
    const days = Math.floor(mins / 1440);
    if (days < 7) return days + 'd';
    const d = new Date(t);
    return ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.getMonth()] + ' ' + d.getDate();
  }

  function matches(ticket, query) {
    const q = (query || '').trim().toLowerCase();
    if (!q) return true;
    const hay = [ticket.title, ticket.summary, ticket.kind, ticket.project, ...(ticket.related_projects || []), '#' + ticket.id,
      ...(ticket.tags || []).map(t => '#' + t), ...(ticket.messages || []).map(m => m.text)].join('\n').toLowerCase();
    return q.split(/\s+/).every(word => hay.includes(word));
  }

  /// Days on which a set of tickets saw any attention at all (a message, a log entry). One minute or ten
  /// hours both count as one used day.
  function usedDays(tickets) {
    const days = new Set();
    for (const t of tickets) {
      for (const m of t.messages || []) if (m.role !== 'system' && m.at) days.add(dayOf(m.at));
      for (const e of t.log || []) days.add(e.date);
    }
    return [...days].sort();
  }

  function streak(days, today) {
    const set = new Set(days);
    // A streak survives until the end of today: start from yesterday when today has no entry yet.
    let day = set.has(today) ? today : addDays(today, -1);
    let n = 0;
    while (set.has(day)) { n++; day = addDays(day, -1); }
    return n;
  }

  /// { name → { name, days: { date → { count, value, unit, notes, tickets } }, total, streak, last } }
  function habits(tickets, today) {
    const out = {};
    for (const t of visible(tickets)) {
      for (const e of t.log || []) {
        const name = (e.name || '').toLowerCase();
        if (!name) continue;
        const habit = out[name] || (out[name] = { name, days: {}, unit: '' });
        const day = habit.days[e.date] || (habit.days[e.date] = { count: 0, value: 0, notes: [], tickets: [] });
        day.count++;
        if (typeof e.value === 'number') day.value += e.value;
        if (e.unit) habit.unit = e.unit;
        if (e.note) day.notes.push(e.note);
        if (!day.tickets.includes(t.id)) day.tickets.push(t.id);
      }
    }
    for (const habit of Object.values(out)) {
      const days = Object.keys(habit.days).sort();
      habit.total = days.length;
      habit.streak = streak(days, today);
      habit.last = days[days.length - 1];
      habit.sum = days.reduce((s, d) => s + habit.days[d].value, 0);
      habit.week = days.filter(d => diffDays(d, today) >= 0 && diffDays(d, today) < 7).length;
    }
    return Object.values(out).sort((a, b) => (b.last || '').localeCompare(a.last || ''));
  }

  /// Columns of a GitHub-style heatmap: `weeks` arrays of 7 days (Sunday first), ending with today's week.
  /// Days after today are null.
  function heatmap(today, weeks) {
    const end = addDays(today, 6 - weekday(today));
    const start = addDays(end, -(weeks * 7 - 1));
    const cols = [];
    for (let w = 0; w < weeks; w++) {
      const col = [];
      for (let d = 0; d < 7; d++) {
        const day = addDays(start, w * 7 + d);
        col.push(diffDays(day, today) < 0 ? null : day);
      }
      cols.push(col);
    }
    return cols;
  }

  /// 0–4 for a heatmap cell, relative to the habit's own busiest day.
  function level(value, max) {
    if (!value) return 0;
    if (max <= 1) return 4;
    return Math.max(1, Math.min(4, Math.ceil((value / max) * 4)));
  }

  function projectStats(projectId, tickets, today, contextTicketIDs = []) {
    const mine = visible(tickets).filter(t => t.project === projectId || (t.related_projects || []).includes(projectId) || contextTicketIDs.includes(t.id));
    const days = usedDays(mine);
    const shipping = mine.filter(t => t.kind === 'shipping');
    const kinds = {};
    for (const t of mine) kinds[t.kind] = (kinds[t.kind] || 0) + 1;
    return {
      tickets: mine,
      open: mine.filter(t => t.status !== 'closed').length,
      closed: mine.filter(t => t.status === 'closed').length,
      usedDays: days.length,
      days,
      lastDay: days[days.length - 1] || null,
      idleDays: days.length ? diffDays(days[days.length - 1], today) : null,
      kinds,
      takeaways: mine.flatMap(t => (t.takeaways || []).map(text => ({ text, ticket: t.id }))),
      shipped: shipping.filter(t => t.status === 'closed').length,
      shipping: shipping.filter(t => t.status !== 'closed').length,
    };
  }

  /// Should this project be nudged towards becoming visible (a paper, a video, a post)?
  function shipNudge(project, stats, threshold = 5) {
    if (stats.shipped > 0 || stats.shipping > 0) return false;
    return !!project.important || stats.usedDays >= threshold;
  }

  /// What happened in a set of tickets, newest day first: [{ day, items: [{ ticket, title, kind, what }] }]
  function timeline(tickets) {
    const byDay = {};
    for (const t of tickets) {
      const seen = new Set();
      for (const m of t.messages || []) {
        if (m.role !== 'human') continue;
        const day = dayOf(m.at);
        if (seen.has(day)) continue;
        seen.add(day);
        (byDay[day] = byDay[day] || []).push({ ticket: t.id, title: t.title, kind: t.kind, status: t.status, what: snippet(m.text, 110) });
      }
    }
    return Object.keys(byDay).sort().reverse().map(day => ({ day, items: byDay[day] }));
  }

  /// Bars for the Gantt chart: tickets that span days. Returns { start, days, bars: [{ ticket, from, length }] }.
  function gantt(tickets, today, minDays = 21) {
    const spans = visible(tickets).filter(t => t.start && t.due && t.due >= t.start);
    const shown = spans.filter(t => t.status !== 'closed' || diffDays(t.due, today) <= 14);
    let start = addDays(today, -3), end = addDays(today, minDays - 4);
    for (const t of shown) {
      if (t.start < start) start = t.start;
      if (t.due > end) end = t.due;
    }
    if (diffDays(start, today) > 30) start = addDays(today, -30);
    const days = diffDays(start, end) + 1;
    const bars = shown
      .sort((a, b) => a.start.localeCompare(b.start) || a.due.localeCompare(b.due))
      .map(t => {
        const from = Math.max(0, diffDays(start, t.start));
        const to = Math.min(days - 1, diffDays(start, t.due));
        return { ticket: t, from, length: Math.max(1, to - from + 1), late: t.status !== 'closed' && t.due < today };
      });
    return { start, days, today: diffDays(start, today), bars };
  }

  function dueBucket(due, today) {
    if (!due) return 'someday';
    const d = diffDays(today, due);
    if (d < 0) return 'overdue';
    if (d === 0) return 'today';
    if (d <= 7) return 'week';
    return 'later';
  }

  /// A stable hue for a project or habit name.
  function hue(name) {
    let h = 0;
    for (const ch of name || '') h = (h * 31 + ch.codePointAt(0)) % 360;
    return h;
  }

  /// The open tickets of a project that most deserve a look: what is due soonest, then what waits for you,
  /// then what moved last.
  function topTickets(tickets, today, n = 3) {
    const urgency = { overdue: 0, today: 1, week: 2, later: 3, someday: 3 };
    const turn = { waiting_human: 0, needs_agent: 1, unprocessed: 1 };
    return tickets.filter(t => t.status !== 'closed' && t.merged_into == null)
      .sort((a, b) => urgency[dueBucket(a.due, today)] - urgency[dueBucket(b.due, today)]
        || (turn[a.status] ?? 2) - (turn[b.status] ?? 2)
        || (a.due || '9999').localeCompare(b.due || '9999')
        || (b.updated || '').localeCompare(a.updated || ''))
      .slice(0, n);
  }

  /// Projects by category, the familiar three first: [{ category, projects }].
  function groupProjects(projects) {
    const order = ['research', 'class', 'personal'];
    const groups = {};
    for (const p of projects) (groups[(p.type || 'personal').toLowerCase()] = groups[(p.type || 'personal').toLowerCase()] || []).push(p);
    return Object.keys(groups)
      .sort((a, b) => (order.indexOf(a) < 0 ? 99 : order.indexOf(a)) - (order.indexOf(b) < 0 ? 99 : order.indexOf(b)) || a.localeCompare(b))
      .map(category => ({ category, projects: groups[category] }));
  }

  const internalTag = tag => tag.startsWith('workspace-plan-');

  const under = (tag, ancestor) => tag === ancestor || tag.startsWith(ancestor + '/');

  /// The tag vocabulary as a tree in reading order, loose tags (on tickets, not in the vocabulary) first:
  /// [{ id, name, depth, meaning, action, count, defined, legacy }]. A count includes what hangs below the tag.
  function tagTable(tickets, structure) {
    const used = {};
    for (const t of visible(tickets)) for (const tag of t.tags || []) if (!internalTag(tag)) used[tag] = (used[tag] || 0) + 1;
    const vocabulary = structure.tags || [];
    const count = id => Object.keys(used).filter(tag => under(tag, id)).reduce((n, tag) => n + used[tag], 0);
    const row = (t, defined) => ({ id: t.id, name: t.id.split('/').pop(), depth: t.id.split('/').length, meaning: t.meaning || '', action: t.action || '',
      count: count(t.id), defined, legacy: /^LEGACY\b/.test(t.meaning || '') });
    const ordered = [];
    const walk = parent => {
      for (const t of vocabulary) {
        const cut = t.id.lastIndexOf('/');
        const mine = cut < 0 ? null : t.id.slice(0, cut);
        // A tag whose parent is missing still shows, at the top level.
        if (mine === parent || (parent === null && mine !== null && !vocabulary.some(o => o.id === mine))) { ordered.push(row(t, true)); walk(t.id); }
      }
    };
    walk(null);
    const loose = Object.keys(used).filter(id => !vocabulary.some(t => t.id === id)).sort().map(id => ({ ...row({ id }, false), count: used[id] }));
    return [...loose, ...ordered];
  }

  /// A project's Markdown context as cards: { title, intro, sections: [{ title, body, log }] }.
  /// A lone top heading is the document's title; the headings one level down are the sections.
  function contextSections(markdown) {
    const lines = String(markdown || '').split('\n');
    const heads = [];
    let fenced = false;
    lines.forEach((line, i) => {
      if (/^\s*```/.test(line)) fenced = !fenced;
      const m = fenced ? null : /^(#{1,4})\s+(.+?)\s*#*$/.exec(line);
      if (m) heads.push({ i, level: m[1].length, title: m[2] });
    });
    const text = (from, to) => lines.slice(from, to).join('\n').trim();
    if (!heads.length) return { title: '', intro: text(0, lines.length), sections: [] };
    const titled = heads.length > 1 && heads.slice(1).every(h => h.level > heads[0].level);
    const rest = titled ? heads.slice(1) : heads;
    const level = Math.min(...rest.map(h => h.level));
    const tops = rest.filter(h => h.level === level);
    const intro = [text(0, heads[0].i), titled ? text(heads[0].i + 1, tops[0].i) : ''].filter(Boolean).join('\n\n');
    return { title: titled ? heads[0].title : '', intro,
      sections: tops.map((h, n) => ({ title: h.title, body: text(h.i + 1, n + 1 < tops.length ? tops[n + 1].i : lines.length),
        log: /\b(log|history|changelog|journal)\b/i.test(h.title) })) };
  }

  // MARK: Designs drawn from the rules themselves (JSON Canvas)

  /// How tall a card must be for its text at this width (13px text; CJK counts double).
  function textHeight(text, width) {
    const room = Math.max(60, width - 30);
    let rows = 0;
    for (const line of String(text).split('\n')) {
      let units = 0;
      for (const ch of line.replace(/\*\*|`/g, '')) units += ch.codePointAt(0) > 0x2e80 ? 13.5 : 7.1;
      rows += Math.max(1, Math.ceil(units / room));
    }
    return 28 + rows * 20;
  }

  function board() {
    const nodes = [], edges = [];
    const b = {
      nodes, edges,
      card(id, text, x, y, width, color) {
        const node = { id, type: 'text', text, x, y, width, height: textHeight(text, width) };
        if (color) node.color = color;
        nodes.push(node);
        return node;
      },
      /// Cards stacked in a labelled box; returns the box.
      column(id, label, x, y, width, color, texts) {
        let top = y + 20;
        texts.forEach((text, i) => { top += b.card(id + '-' + i, text, x + 20, top, width - 40, color).height + 14; });
        const group = { id, type: 'group', label, x, y, width, height: top - y + 6 };
        if (color) group.color = color;
        nodes.unshift(group);
        return group;
      },
      link(from, to, label, fromSide = 'right', toSide = 'left') {
        const edge = { id: 'e' + edges.length, fromNode: from, fromSide, toNode: to, toSide };
        if (label) edge.label = label;
        edges.push(edge);
      },
    };
    return b;
  }

  const plural = (n, word) => n + ' ' + word + (n === 1 ? '' : 's');

  /// The whole loop on one page: what you put in, what the agent is told, what it may do, where it lands.
  function systemDesign(S) {
    const b = board();
    const st = S.structure || {}, kinds = st.kinds || [], projects = st.projects || [], tags = st.tags || [];
    const tickets = visible(S.tickets || []);
    const principles = tickets.filter(t => t.kind === 'principle').length;
    const tools = S.tools || [];
    const area = name => tools.filter(t => t.area === name).map(t => '- `' + t.name + '`').join('\n');
    const W = 360, GAP = 90;
    const x = i => i * (W + GAP);
    b.column('you', 'You — input', x(0), 0, W, '4', [
      '**New Ticket** (shortcut)\nanything: text, #hashtags, screenshots, files',
      '⌘↩ **Send** — the agent classifies a new ticket\n⇧⌘↩ **Append** — the agent files it into an existing ticket\n⌃↩ **Save** — no agent; your #hashtags decide',
      '**Reply** on a ticket (⌘↩), or **Add as note** (⌃↩, no agent)',
      '**Corrections**\nchange a kind or project by hand, or press Correct agent — logged and sent with every prompt',
      '**The rules you own**\nInstructions · Kinds & rules · Tags · Principles · Designs',
    ]);
    b.column('told', 'What the agent is told each turn', x(1), 0, W, '5', [
      '**Instructions** — standing, short',
      `**Kinds** (${kinds.length}) — what it looks like → what to do`,
      `**Tags** (${tags.length}) — layered vocabulary: meaning → action, plus the classification map`,
      `**Projects** (${projects.length}) — category, note, maintained context`,
      `**Principles** (${principles}) and **Corrections** (${(S.corrections || []).length}) — override everything else`,
      `**Designs** (${(S.designs || []).length}) — flowcharts it can read and redraw`,
      '**Other tickets** — to reuse projects and tags, link work, find duplicates',
      '**This ticket** — its fields and the conversation',
    ]);
    b.column('agent', 'Agent turn', x(2), 0, W, '6', [
      `**${(S.settings || {}).agent || 'Claude Code, Codex or Pi'}**\none fresh run per turn; any agent can pick up any ticket`,
      `**Works first** — ${(S.settings || {}).accessNote || 'reads files, searches the web, runs code inside its access'}`,
      '**Answers** in Markdown, in your language',
      '**Decides** in one `ticket` block at the end of the reply',
    ]);
    b.column('space', 'Agent’s action space', x(3), 0, W, '2', [
      '**This ticket**\ntitle · summary · kind · project · related projects · tags · status · start / due · log (habits) · takeaways',
      '**Tickets**\n' + (area('tickets') || '—'),
      '**Projects**\n' + (area('projects') || '—'),
      '**Tags and kinds**\n' + (area('tags') || '—'),
      '**Designs**\n' + (area('designs') || '—'),
      '**Never**: spend money, send messages as you, delete your files',
    ]);
    b.column('files', 'Stored as plain files', x(4), 0, W, '', [
      `\`tickets/NNNN.md\` — ${plural(tickets.length, 'ticket')}, one Markdown file each`,
      '`structure.json` — kinds, projects',
      '`tags/` — the tag vocabulary: SKILL.md (rules), references/index.md and deeper files',
      '`designs/*.canvas` — designs (open in Obsidian too)',
      '`agent/decisions.jsonl` — every change the agent made, with its reason',
      '`agent/corrections.jsonl` · `agent/instructions.md`',
    ]);
    b.column('views', 'Views — what you read', x(5), 0, W, '1', [
      '**Inbox** — Your turn · Agent’s turn · All open · Closed',
      '**Projects** — by category, top tickets, used days, context',
      '**Habits** heatmaps · **Plan** Gantt and todos',
      '**Library** — principles, answers, resources, designs',
      '**Tags** — every tag, its meaning and action',
      '**Agent** — tools, decision log, full prompt',
    ]);
    b.link('you', 'told', 'starts a turn');
    b.link('told', 'agent', 'one prompt');
    b.link('agent', 'space', 'reply + ticket block');
    b.link('space', 'files', 'the app applies and logs it');
    b.link('files', 'views', 'drawn from the files');
    b.link('views', 'you', 'you react: reply, correct, edit a rule', 'bottom', 'bottom');
    return { nodes: b.nodes, edges: b.edges };
  }

  /// How a capture gets its kind, project, tags and status — drawn from the current kinds, projects and tags.
  function categorizationDesign(S) {
    const b = board();
    const st = S.structure || {}, kinds = st.kinds || [], projects = st.projects || [], tags = st.tags || [];
    const SP = 400, RX = 500;
    let y = 0;
    const step = (id, text, color) => { const n = b.card(id, text, 0, y, SP, color); return n; };

    const capture = step('capture', '**A capture arrives**\ntext, #hashtags, screenshots, files', '4');
    const save = b.card('save', '**Save** — no agent\n#kind sets the kind, #project the project, every other #word becomes a tag. Status: Your turn.', RX, y, 440);
    const append = b.card('append', '**Append** — the agent picks the most relevant open ticket; the capture becomes its latest message, and steps 1–5 apply to that ticket.', RX, y + save.height + 24, 440);
    b.link('capture', 'save', '⌃↩');
    b.link('capture', 'append', '⇧⌘↩');
    y += Math.max(capture.height, save.height + 24 + append.height) + 80;

    const kindStep = step('kind', '**1 · Kind** — exactly one\nThe agent matches the capture to a kind’s description; a #hashtag is a strong hint. Nothing fits → Uncategorized, or `add_kind` when two or more tickets share a shape.', '6');
    b.link('capture', 'kind', '⌘↩ Send', 'bottom', 'top');
    const VIEWS = [['thread', 'Inbox and its project page'], ['todo', 'Plan → Todos'], ['plan', 'Plan → Gantt chart'], ['habit', 'Habits heatmap'],
      ['resource', 'Library → Resources'], ['principle', 'Library → Principles, and the agent’s prompt']];
    let cx = RX, tallest = 0;
    VIEWS.forEach(([view, where]) => {
      const mine = kinds.filter(k => k.view === view);
      if (!mine.length) return;
      // Many kinds share the plain "thread" view: two cards side by side keep the drawing short.
      const cols = mine.length > 5 ? 2 : 1, CW = 300, width = cols * CW + (cols - 1) * 14 + 40;
      const tops = Array(cols).fill(y + 20);
      mine.forEach((k, i) => {
        const c = tops.indexOf(Math.min(...tops));
        const node = b.card('kind-' + k.id, `${k.icon} **${k.label}** \`#${k.id}\`\n${k.description}\n→ ${k.rule}`, cx + 20 + c * (CW + 14), tops[c], CW);
        tops[c] += node.height + 14;
      });
      const height = Math.max(...tops) - y + 6;
      b.nodes.unshift({ id: 'view-' + view, type: 'group', label: 'shown in: ' + where, x: cx, y, width, height, color: '5' });
      tallest = Math.max(tallest, height);
      cx += width + 40;
    });
    const firstView = VIEWS.find(([view]) => kinds.some(k => k.view === view));
    if (firstView) b.link('kind', 'view-' + firstView[0], 'the kind decides the view and the rule');
    y += Math.max(kindStep.height, tallest) + 80;

    const projectStep = step('project', '**2 · Project** — zero or one\nReuse an existing project when the capture clearly belongs to it. A new project is created only when you name something new. A ticket shared by several projects lists the others as related.', '6');
    const groups = groupProjects(projects);
    const projectCard = b.card('projects', groups.length ? groups.map(g => `**${g.category}** — ${g.projects.map(p => p.name).join(', ')}`).join('\n') : 'No projects yet.', RX, y, 520, '5');
    b.link('kind', 'project', '', 'bottom', 'top');
    b.link('project', 'projects', 'categories');
    y += Math.max(projectStep.height, projectCard.height) + 80;

    const tagStep = step('tags', '**3 · Tags** — any number\nOnly tags from the vocabulary in the tags folder: full paths (purpose / field / concept), each with a meaning and an action. With a classification map, exactly one top-level purpose per ticket. A new tag needs `define_tag` under an existing parent; loose or duplicate tags get `merge_tags`; empty ones `delete_tag`. Undefined tags are dropped.', '6');
    const top = tags.filter(t => t.id.split('/').length <= 2 && !/^LEGACY\b/.test(t.meaning || '')), deeper = tags.length - tags.filter(t => t.id.split('/').length <= 2).length;
    const brief = text => { const first = String(text || '').split(/(?<=[.;。])\s/)[0]; return first.length > 90 ? first.slice(0, 90) + '…' : first; };
    const tagCard = b.card('taglist', top.length ? top.map(t => `${t.id.includes('/') ? '  ' : ''}\`${t.id}\` — ${brief(t.meaning) || '(no meaning yet)'}`).join('\n') + (deeper ? `\n… and ${deeper} deeper tag${deeper === 1 ? '' : 's'} in tags/references/` : '')
      : 'No tags defined yet. Tags you type by hand show up under Tags as “needs a meaning”.', RX, y, 680, '5');
    b.link('project', 'tags', '', 'bottom', 'top');
    b.link('tags', 'taglist', 'registry');
    y += Math.max(tagStep.height, tagCard.height) + 80;

    const act = step('act', '**4 · Follow the kind’s rule**\nDo the useful first step (search, read, run code), reply briefly, and use tools to organize: create or update tickets, keep the project context and plan current, record principles, redraw designs.', '6');
    b.link('tags', 'act', '', 'bottom', 'top');
    y += act.height + 80;
    const status = step('status', '**5 · Status**\nYour turn when it needs you · Closed when nothing is left.', '4');
    b.link('act', 'status', '', 'bottom', 'top');
    // The feedback loop runs up the left side, clear of everything else.
    b.card('fix', '**You disagree?**\nChange the kind or project by hand, or press Correct agent. The correction is logged and sent with every prompt, so the next similar capture is classified your way.', -520, y - 40, 400, '1');
    b.link('status', 'fix', 'you review', 'left', 'right');
    b.link('fix', 'kind', 'corrections', 'top', 'left');
    return { nodes: b.nodes, edges: b.edges };
  }

  return { addDays, diffDays, weekday, dayOf, hashtags, tagAtCaret, visible, snippet, ago, matches, usedDays, streak,
    habits, heatmap, level, projectStats, shipNudge, timeline, gantt, dueBucket, hue, topTickets, groupProjects,
    internalTag, tagTable, contextSections, textHeight, systemDesign, categorizationDesign };
});
