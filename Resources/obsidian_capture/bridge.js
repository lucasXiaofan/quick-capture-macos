// Runs inside Obsidian through its CLI. No plugin or network server needed.
// The CLI does not await promises, so `save` runs asynchronously and is polled via `status`.
if (app.vault.adapter.getBasePath() !== p.vault) throw Error('Wrong vault: check your configuration');
const state = globalThis.__roadQuickCapture ||= {snapshots: {}, results: {}};
if (p.action === 'ping') return {vault: app.vault.getName()};
if (p.action === 'snapshot') {
    const view = app.workspace.activeLeaf?.view;
    const file = app.workspace.getActiveFile();
    const editor = view?.getMode?.() === 'source' ? view.editor : null;
    const note = file?.extension === 'md' && !p.diary ? file : null;
    state.snapshots[p.id] = {
        file: note,
        editor: note && view?.file === file ? editor : null,
        cursor: editor?.getCursor('from'), // Left/start of selection; never replace selection.
        before: editor?.getValue()
    };
    const snap = state.snapshots[p.id];
    return {path: note?.path || p.diary_path, note: !!note, cursor: !!(snap.editor && snap.cursor)};
}
if (p.action === 'status') return state.results[p.id] || null;
if (p.action === 'forget') {
    delete state.snapshots[p.id]; delete state.results[p.id]; return true;
}
if (p.action === 'save') {
    if (state.results[p.id]) return true;
    state.results[p.id] = {pending: true};
    (async () => {
        const snap = (!p.force_diary && state.snapshots[p.id]) || {};
        let file = snap.file;
        if (!file || app.vault.getAbstractFileByPath(file.path) !== file) {
            file = app.vault.getAbstractFileByPath(p.diary_path);
            if (!file) {
                const parts = p.diary_path.split('/'); parts.pop();
                let folder = '';
                for (const part of parts) {
                    folder = folder ? folder + '/' + part : part;
                    if (!app.vault.getAbstractFileByPath(folder)) await app.vault.createFolder(folder);
                }
                file = await app.vault.create(p.diary_path, p.template);
            }
        }
        if (file.extension !== 'md') throw Error('Destination is not a Markdown note');
        // Use the live editor when open, preserving unsaved changes and undo history.
        const views = app.workspace.getLeavesOfType('markdown').map(l => l.view);
        const view = views.find(v => v.file === file && snap.editor && v.editor === snap.editor)
            || views.find(v => v.file === file && v.getMode?.() === 'source');
        if (view?.editor) {
            const editor = view.editor;
            let content = editor.getValue();
            if (file.path === p.diary_path && !content.trim()) {
                editor.replaceRange(p.template, {line: 0, ch: 0});
                content = editor.getValue();
            }
            // If editing occurred during the dialog, append instead of using a stale cursor.
            const atCursor = snap.editor && editor === snap.editor && content === snap.before && snap.cursor;
            const pos = atCursor ? snap.cursor : editor.offsetToPos(content.length);
            editor.replaceRange(p.text, pos);
            await view.save();
            state.results[p.id] = {path: file.path, cursor: !!atCursor};
        } else {
            await app.vault.process(file, content =>
                (file.path === p.diary_path && !content.trim() ? p.template : content) + p.text);
            state.results[p.id] = {path: file.path, cursor: false};
        }
        delete state.snapshots[p.id];
    })().catch(e => { state.results[p.id] = {error: String(e)}; });
    return true;
}
throw Error('Unknown bridge action');
