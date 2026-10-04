// Runs inside Obsidian through its CLI. No plugin or network server needed.
// The CLI does not await promises, so a `save` that can't finish synchronously is polled via `status`.
if (app.vault.adapter.getBasePath() !== p.vault) throw Error('Wrong vault: check your configuration');
const state = globalThis.__roadQuickCapture ||= {snapshots: {}, results: {}};
if (p.action === 'ping') return {vault: app.vault.getName()};
if (p.action === 'snapshot') {
    const view = app.workspace.activeLeaf?.view;
    const file = app.workspace.getActiveFile();
    const editor = view?.getMode?.() === 'source' ? view.editor : null;
    const note = file?.extension === 'md' && !p.diary ? file : null;
    // Nothing calls `forget` any more (each CLI call flashes a Dock icon); drop stale snapshots here.
    for (const [id, s] of Object.entries(state.snapshots)) if (Date.now() - s.t > 3600e3) delete state.snapshots[id];
    state.snapshots[p.id] = {
        t: Date.now(),
        file: note,
        editor: note && view?.file === file ? editor : null,
        cursor: editor?.getCursor('from'), // Left/start of selection; never replace selection.
        before: editor?.getValue()
    };
    const snap = state.snapshots[p.id];
    return {path: note?.path || p.diary_path, note: !!note, cursor: !!(snap.editor && snap.cursor)};
}
if (p.action === 'status') {
    const r = state.results[p.id] || null;
    if (r && !r.pending) delete state.results[p.id]; // Reading a finished result consumes it.
    return r;
}
if (p.action === 'forget') {
    delete state.snapshots[p.id]; delete state.results[p.id]; return true;
}
if (p.action === 'save') {
    // A repeated save (retry after a lost reply) returns the first one's result instead of writing again.
    if (state.results[p.id]) return state.results[p.id];
    const snap = (!p.force_diary && state.snapshots[p.id]) || {};
    const done = r => {
        for (const [id, x] of Object.entries(state.results)) if (Date.now() - x.t > 3600e3) delete state.results[id];
        delete state.snapshots[p.id];
        return state.results[p.id] = {...r, t: Date.now()};
    };
    // Edits the live editor when the note is open, preserving unsaved changes and undo history.
    // Synchronous, so the common case finishes inside this one CLI call (each call flashes a Dock icon).
    const intoEditor = file => {
        const views = app.workspace.getLeavesOfType('markdown').map(l => l.view);
        const view = views.find(v => v.file === file && snap.editor && v.editor === snap.editor)
            || views.find(v => v.file === file && v.getMode?.() === 'source');
        if (!view?.editor) return null;
        const editor = view.editor;
        let content = editor.getValue();
        if (file.path === p.diary_path && !content.trim()) {
            editor.replaceRange(p.template, {line: 0, ch: 0});
            content = editor.getValue();
        }
        // If editing occurred during the dialog, append instead of using a stale cursor.
        const atCursor = snap.editor && editor === snap.editor && content === snap.before && snap.cursor;
        editor.replaceRange(p.text, atCursor ? snap.cursor : editor.offsetToPos(content.length));
        Promise.resolve(view.save()).catch(() => {}); // Obsidian also autosaves; the edit is already in.
        return {path: file.path, cursor: !!atCursor};
    };
    let file = snap.file;
    if (!file || app.vault.getAbstractFileByPath(file.path) !== file) file = app.vault.getAbstractFileByPath(p.diary_path);
    if (file && file.extension !== 'md') return done({error: 'Error: Destination is not a Markdown note'});
    const quick = file && intoEditor(file);
    if (quick) return done(quick);
    // Note not open (or diary missing): finish asynchronously; the app polls `status`.
    state.results[p.id] = {pending: true, t: Date.now()};
    (async () => {
        if (!file) {
            const parts = p.diary_path.split('/'); parts.pop();
            let folder = '';
            for (const part of parts) {
                folder = folder ? folder + '/' + part : part;
                if (!app.vault.getAbstractFileByPath(folder)) await app.vault.createFolder(folder);
            }
            file = await app.vault.create(p.diary_path, p.template);
        }
        const r = intoEditor(file);
        if (r) return done(r);
        await app.vault.process(file, content =>
            (file.path === p.diary_path && !content.trim() ? p.template : content) + p.text);
        done({path: file.path, cursor: false});
    })().catch(e => done({error: String(e)}));
    return state.results[p.id];
}
throw Error('Unknown bridge action');
