// Isolated tests: no Obsidian instance or real vault files are modified.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const bridge = new Function('p', 'app', fs.readFileSync(__dirname + '/../Resources/obsidian_capture/bridge.js', 'utf8'));
async function scenario({active = true, editor = true, changed = false, diary = false, empty = false, force = false} = {}) {
  delete globalThis.__roadQuickCapture;
  const files = new Map();
  const note = {path: 'note.md', extension: 'md', text: 'abcd'};
  if (active) files.set(note.path, note);
  if (empty) files.set('Daily/today.md', {path: 'Daily/today.md', extension: 'md', text: ''});
  const ed = {getValue: () => note.text, getCursor: () => ({line: 0, ch: 2}),
    offsetToPos: n => ({line: 0, ch: n}),
    replaceRange: (s, p) => { note.text = note.text.slice(0, p.ch) + s + note.text.slice(p.ch); }};
  const view = {file: note, editor: ed, getMode: () => editor ? 'source' : 'preview', save: async () => {}};
  const app = {
    workspace: {activeLeaf: active ? {view} : null, getActiveFile: () => active ? note : null,
      getLeavesOfType: () => active ? [{view}] : []},
    vault: {adapter: {getBasePath: () => '/test'}, getAbstractFileByPath: p => files.get(p),
      createFolder: async p => files.set(p, {}),
      create: async (p, text) => { const f = {path:p, text, extension:'md'}; files.set(p, f); return f; },
      process: async (f, fn) => { f.text = fn(f.text); }}
  };
  const p = {vault:'/test', id:'1', diary_path:'Daily/today.md', diary, template:'TEMPLATE', text:'CAPTURE'};
  const snap = bridge({...p, action:'snapshot'}, app);
  assert.equal(snap.note, active && !diary);
  assert.equal(snap.cursor, active && !diary && editor);
  if (changed) note.text += '!';
  bridge({...p, action:'save', force_diary: force}, app);
  await new Promise(resolve => setImmediate(resolve));
  const result = bridge({...p, action:'status'}, app);
  assert.ok(result.path, JSON.stringify(result));
  return files.get(result.path).text;
}
(async () => {
  assert.equal(await scenario(), 'abCAPTUREcd');
  assert.equal(await scenario({editor:false}), 'abcdCAPTURE');
  assert.equal(await scenario({changed:true}), 'abcd!CAPTURE');
  assert.equal(await scenario({active:false}), 'TEMPLATECAPTURE');
  assert.equal(await scenario({diary:true}), 'TEMPLATECAPTURE');
  assert.equal(await scenario({diary:true, empty:true}), 'TEMPLATECAPTURE');
  assert.equal(await scenario({force:true}), 'TEMPLATECAPTURE');
  console.log('7 bridge tests passed: cursor, reading view, stale cursor, missing diary, diary-only, empty diary, switched to diary');
})().catch(e => {console.error(e); process.exitCode = 1;});
