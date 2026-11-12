// Tests the Tickets pages' pure helpers (hashtags, habits, used days, Gantt, due buckets).
const assert = require('node:assert/strict');
const path = require('node:path');
const L = require(path.join(__dirname, '..', 'Resources', 'tickets', 'logic.js'));

assert.equal(L.addDays('2026-11-10', 1), '2026-11-11');
assert.equal(L.addDays('2026-03-01', -1), '2026-02-28');
assert.equal(L.addDays('2026-10-31', 2), '2026-11-02');  // across the DST change
assert.equal(L.diffDays('2026-11-10', '2026-11-15'), 5);
assert.equal(L.weekday('2026-11-10'), 2);  // Tuesday

assert.deepEqual(L.hashtags('meditation 5 min #habit #CS646\n# Heading is not a tag, nor is a#b'), ['habit', 'cs646']);
assert.deepEqual(L.hashtags('中文 #想法 ok'), ['想法']);
assert.deepEqual(L.tagAtCaret('fix it #cs', 10), { start: 7, query: 'cs' });
assert.equal(L.tagAtCaret('fix it #cs done', 15), null);
assert.deepEqual(L.tagAtCaret('#', 1), { start: 0, query: '' });

const msg = (role, at, text = 'x') => ({ role, at, text });
const tickets = [
  { id: 1, title: 'meditation', kind: 'habit', project: '', status: 'closed', tags: [], messages: [msg('human', '2026-11-08T08:00:00-05:00')],
    log: [{ date: '2026-11-08', name: 'meditation', value: 5, unit: 'min' }] },
  { id: 2, title: 'meditation', kind: 'habit', project: '', status: 'closed', tags: [], messages: [msg('human', '2026-11-09T08:00:00-05:00')],
    log: [{ date: '2026-11-09', name: 'Meditation', value: 10, unit: 'min', note: 'calm' }] },
  { id: 3, title: 'hw2', kind: 'plan', project: 'cs646', status: 'waiting_human', tags: ['ir'], start: '2026-11-12', due: '2026-11-15',
    messages: [msg('human', '2026-11-09T10:00:00-05:00', 'finish hw2'), msg('agent', '2026-11-09T10:01:00-05:00'), msg('human', '2026-11-10T09:00:00-05:00')],
    takeaways: ['BM25 saturates term frequency'] },
  { id: 4, title: 'bm25 vs ql', kind: 'review', project: 'cs646', status: 'closed', tags: [], messages: [msg('human', '2026-11-10T11:00:00-05:00', 'practice **question**')] },
  { id: 5, title: 'old source', kind: 'review', project: 'cs646', status: 'closed', merged_into: 4, tags: [], messages: [msg('human', '2026-10-01T11:00:00-05:00')] },
];

const habits = L.habits(tickets, '2026-11-10');
assert.equal(habits.length, 1);
assert.equal(habits[0].name, 'meditation');
assert.equal(habits[0].total, 2);
assert.equal(habits[0].streak, 2);  // yesterday and the day before; today isn't over yet
assert.equal(habits[0].sum, 15);
assert.deepEqual(habits[0].days['2026-11-09'].notes, ['calm']);
assert.equal(L.streak(['2026-11-07', '2026-11-08'], '2026-11-10'), 0);
assert.equal(L.streak(['2026-11-09', '2026-11-10'], '2026-11-10'), 2);

const cols = L.heatmap('2026-11-10', 4);
assert.equal(cols.length, 4);
assert.equal(cols[3][2], '2026-11-10');  // Tuesday of the last week
assert.equal(cols[3][3], null);          // tomorrow isn't drawn
assert.equal(cols[0][0], '2026-10-18');
assert.equal(L.level(0, 10), 0);
assert.equal(L.level(10, 10), 4);
assert.equal(L.level(1, 10), 1);
assert.equal(L.level(1, 1), 4);

const stats = L.projectStats('cs646', tickets, '2026-11-12');
assert.equal(stats.tickets.length, 2);  // the merged-away source isn't counted
assert.equal(stats.usedDays, 2);        // Nov 9 and Nov 10, however many messages
assert.equal(stats.open, 1);
assert.equal(stats.idleDays, 2);
assert.deepEqual(stats.takeaways, [{ text: 'BM25 saturates term frequency', ticket: 3 }]);
assert.equal(L.shipNudge({ important: false }, stats), false);
assert.equal(L.shipNudge({ important: true }, stats), true);
assert.equal(L.shipNudge({ important: true }, { ...stats, shipping: 1 }), false);

const tl = L.timeline(stats.tickets);
assert.deepEqual(tl.map(d => d.day), ['2026-11-10', '2026-11-09']);
assert.equal(tl[0].items.length, 2);
assert.equal(tl[0].items.find(i => i.ticket === 4).what, 'practice question');

const g = L.gantt(tickets, '2026-11-10');
assert.equal(g.start, '2026-11-07');
assert.equal(g.today, 3);
assert.equal(g.bars.length, 1);
assert.deepEqual([g.bars[0].from, g.bars[0].length, g.bars[0].late], [5, 4, false]);
assert.equal(L.gantt(tickets, '2026-11-20').bars[0].late, true);

assert.equal(L.dueBucket(null, '2026-11-10'), 'someday');
assert.equal(L.dueBucket('2026-11-09', '2026-11-10'), 'overdue');
assert.equal(L.dueBucket('2026-11-10', '2026-11-10'), 'today');
assert.equal(L.dueBucket('2026-11-15', '2026-11-10'), 'week');
assert.equal(L.dueBucket('2026-12-15', '2026-11-10'), 'later');

assert.ok(L.matches(tickets[2], 'cs646 hw2'));
assert.ok(L.matches(tickets[2], '#ir'));
assert.ok(!L.matches(tickets[2], 'meditation'));
assert.equal(L.snippet('**bold** and `code`\n\n```js\nx\n```'), 'bold and code');
assert.equal(L.ago('2026-11-10T10:00:00Z', Date.parse('2026-11-10T10:30:00Z')), '30m');
assert.ok(L.hue('cs646') >= 0 && L.hue('cs646') < 360);
console.log('tickets.test: all passed');

const shared = [{ id: 90, project: 'alpha', related_projects: ['beta', 'alpha'], status: 'waiting_human', kind: 'feature' }];
assert.equal(L.projectStats('alpha', shared, '2026-11-10').tickets.length, 1);
assert.equal(L.projectStats('beta', shared, '2026-11-10').tickets.length, 1);
assert.equal(L.projectStats('gamma', shared, '2026-11-10', [90]).tickets.length, 1);
assert.equal(L.matches(shared[0], 'beta'), true);

// Projects page: the tickets most worth a look, and projects by category.
{
  const t = (id, status, extra = {}) => ({ id, status, updated: '2026-11-0' + id, messages: [], ...extra });
  const top = L.topTickets([t(1, 'waiting_human'), t(2, 'needs_agent', { due: '2026-11-11' }), t(3, 'closed', { due: '2026-11-10' }),
    t(4, 'waiting_human', { due: '2026-12-30' }), t(5, 'needs_agent'), t(6, 'waiting_human', { merged_into: 9 })], '2026-11-12', 3);
  assert.deepEqual(top.map(x => x.id), [2, 4, 1]);  // overdue first, then your turn (the dated one first), never closed or merged
  const groups = L.groupProjects([{ id: 'a', type: 'personal' }, { id: 'b', type: 'Lab' }, { id: 'c', type: 'research' }, { id: 'd' }, { id: 'e', type: 'class' }]);
  assert.deepEqual(groups.map(g => g.category + ':' + g.projects.map(p => p.id).join('')), ['research:c', 'class:e', 'personal:ad', 'lab:b']);
}

// Tags: loose ones (on tickets, not in the vocabulary) first, then the vocabulary as a tree; a count includes sub-tags.
{
  const rows = L.tagTable([{ id: 1, tags: ['career/build', 'loose', 'workspace-plan-x-1'] }, { id: 2, tags: ['career'] }, { id: 3, tags: ['gone'], merged_into: 1 }],
    { tags: [{ id: 'life', meaning: 'm' }, { id: 'career', meaning: 'm', action: 'a' }, { id: 'study', meaning: 'LEGACY -> career' },
      { id: 'career/build', meaning: 'm' }, { id: 'career/build/tooling', meaning: '' }] });
  assert.deepEqual(rows.map(r => `${r.id}:${r.count}:${r.defined}:${r.depth}`),
    ['loose:1:false:1', 'life:0:true:1', 'career:2:true:1', 'career/build:1:true:2', 'career/build/tooling:0:true:3', 'study:0:true:1']);
  assert.equal(rows.find(r => r.id === 'study').legacy, true);
  assert.equal(rows.find(r => r.id === 'career/build').name, 'build');
  assert.deepEqual(L.hashtags('ship it #career/build #Fire'), ['career/build', 'fire']);
  assert.deepEqual(L.tagAtCaret('x #career/bu', 12), { start: 2, query: 'career/bu' });
}

// A project's context becomes cards: a lone top heading is the title, the next level the sections.
{
  const c = L.contextSections('# alpha — context\nUpdated: today\n\n## Goal\nNo paper yet.\n### detail\nmore\n\n## Update log\n- a\n```\n## not a heading\n```');
  assert.equal(c.title, 'alpha — context');
  assert.equal(c.intro, 'Updated: today');
  assert.deepEqual(c.sections.map(x => [x.title, x.log]), [['Goal', false], ['Update log', true]]);
  assert.match(c.sections[0].body, /### detail/);
  assert.match(c.sections[1].body, /## not a heading/);
  assert.deepEqual(L.contextSections('just prose'), { title: '', intro: 'just prose', sections: [] });
  assert.deepEqual(L.contextSections('## A\nx\n## B\ny').sections.map(x => x.title), ['A', 'B']);
}

// The system designs are valid JSON Canvas: unique ids, every edge joins two nodes, every card has room for its text.
{
  const C = require(path.join(__dirname, '..', 'Resources', 'tickets', 'canvas.js'));
  const S = { tickets: [{ id: 1, kind: 'principle', messages: [] }], corrections: [], designs: [], settings: {},
    tools: [{ name: 'create_ticket', area: 'tickets' }, { name: 'define_tag', area: 'tags' }],
    structure: { kinds: [{ id: 'todo', view: 'todo', icon: '☑️', label: 'Todo', description: 'd', rule: 'r' }, { id: 'misc', view: 'thread', icon: '📥', label: 'Misc', description: 'd', rule: 'r' }],
      projects: [{ id: 'cs646', name: 'cs646', type: 'class' }], tags: [{ id: 'exam', meaning: 'm', action: 'a' }] } };
  for (const design of [L.systemDesign(S), L.categorizationDesign(S)]) {
    const ids = design.nodes.map(n => n.id);
    assert.equal(new Set(ids).size, ids.length);
    for (const e of design.edges) assert.ok(ids.includes(e.fromNode) && ids.includes(e.toNode), `edge ${e.id}`);
    for (const n of design.nodes) assert.ok(n.width > 0 && n.height > 0 && Number.isFinite(n.x) && Number.isFinite(n.y));
    assert.ok(C.bounds(design).width > 500);
  }
  assert.match(JSON.stringify(L.systemDesign(S)), /create_ticket/);         // the action space is drawn from the tool list
  assert.match(JSON.stringify(L.categorizationDesign(S)), /`exam`/);        // and the logic from the live structure
  assert.deepEqual(C.autoSides({ x: 0, y: 0, width: 10, height: 10 }, { x: 0, y: 100, width: 10, height: 10 }), ['bottom', 'top']);
  assert.equal(C.nearestSide({ x: 0, y: 0, width: 100, height: 50 }, 96, 20), 'right');
  assert.equal(C.colorOf('4'), C.COLORS[4]);
  assert.equal(C.colorOf('javascript:alert(1)'), '');
  assert.ok(L.textHeight('漢字'.repeat(40), 260) > L.textHeight('ab'.repeat(40), 260));
}
