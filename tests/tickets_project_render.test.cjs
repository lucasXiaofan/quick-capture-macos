// Execute the real page renderer with a minimal DOM surface; no browser or live app writes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const base = path.join(__dirname, '..', 'Resources');
const elements = Object.fromEntries(['nav', 'main', 'toast'].map(id => [id, {
  innerHTML: '', querySelectorAll: () => [], querySelector: () => null,
}]));
const listeners = {}, sent = [];
const context = {
  TKLogic: require(path.join(base, 'tickets/logic.js')),
  QCRender: require(path.join(base, 'ai_chat/render.js')),
  marked: require(path.join(base, 'ai_chat/vendor/marked.umd.js')),
  katex: require(path.join(base, 'ai_chat/vendor/katex/katex.min.js')),
  DOMPurify: { sanitize: html => html },
  document: { getElementById: id => elements[id], querySelectorAll: selector => {
    assert.notEqual(selector, 'details.', 'details state must use a valid CSS selector');
    const details = [...elements.main.innerHTML.matchAll(/<details(?: class="([^"]*)")?>/g)]
      .map(match => ({ className: match[1] || '' }));
    if (selector === 'details') return details;
    if (selector.startsWith('details.')) return details.filter(d => d.className === selector.slice(8));
    return [];
  }, activeElement: null,
    addEventListener: (event, fn) => { listeners[event] = fn; } },
  window: { webkit: { messageHandlers: { tk: { postMessage: msg => sent.push(msg) } } } },
};
vm.runInNewContext(fs.readFileSync(path.join(base, 'tickets/app.js'), 'utf8'), context);
const state = { type: 'state', tickets: [
  { id: 3, title: 'Shared research context', kind: 'feature', project: 'alpha', related_projects: ['beta'], status: 'closed', messages: [], tags: [] },
  { id: 5, title: 'Prepare doctor review', kind: 'plan', project: 'alpha', status: 'waiting_human', start: '2026-11-10', due: '2026-11-12', messages: [], tags: [] },
], structure: { kinds: [{ id: 'plan', view: 'plan', label: 'Plan', icon: 'x' }], projects: [
  { id: 'alpha', name: 'Alpha', type: 'research', context: '## Current state\nA good draft exists.', context_ticket_ids: [3] },
  { id: 'beta', name: 'Beta', type: 'research', context: 'Two research questions.', context_ticket_ids: [3] },
] }, today: '2026-11-10', busy: {}, settings: {}, corrections: [], decisions: [] };
const tk = context.window.TK;
tk.ui.view = 'projects'; tk.ui.project = 'alpha'; tk.receive(state);
assert.match(elements.main.innerHTML, /<h2>Project context<\/h2>/);
assert.match(elements.main.innerHTML, /A good draft exists/);
assert.match(elements.main.innerHTML, /Prepare doctor review/);
assert.match(elements.main.innerHTML, /data-keep="pcontext:alpha"/);
assert.match(elements.main.innerHTML, /data-id="3"/);
tk.ui.project = 'beta'; tk.receive(state);
assert.match(elements.main.innerHTML, /Shared research context/);
tk.ui.view = 'plan'; tk.receive(state);
assert.match(elements.main.innerHTML, /Prepare doctor review/);
assert.doesNotMatch(elements.main.innerHTML, /No plans yet/);
const field = { dataset: { change: 'projectContext', project: 'alpha' }, value: 'Updated context', closest(selector) { return selector === '[data-change]' ? this : null; } };
listeners.change({ target: field });
assert.equal(sent.at(-1).structure.projects[0].context, 'Updated context');
assert.deepEqual(Array.from(sent.at(-1).structure.projects[0].context_ticket_ids), [3]);
console.log('tickets_project_render: all passed');
