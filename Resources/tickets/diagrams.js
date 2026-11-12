// Render fenced Mermaid blocks after Markdown insertion. Keep the original source
// available and leave partial/invalid diagrams readable while replies stream.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.TKDiagrams = api;
})(typeof self !== 'undefined' ? self : globalThis, function () {
  let nextID = 0;
  let queue = Promise.resolve();
  let initialized = false;

  function render(container, engine, sanitize) {
    if (!engine) return queue;
    if (!initialized) {
      engine.initialize({ startOnLoad: false, securityLevel: 'strict',
        theme: 'neutral', flowchart: { htmlLabels: false },
        suppressErrorRendering: true });
      initialized = true;
    }
    container.querySelectorAll('pre code.language-mermaid').forEach(code => {
      const pre = code.parentElement;
      if (pre.dataset.diagram) return;
      pre.dataset.diagram = 'pending';
      const source = code.textContent;
      queue = queue.then(async () => {
        if (!pre.isConnected) return;
        try {
          const { svg } = await engine.render('ticket-diagram-' + (++nextID), source);
          if (!pre.isConnected) return;
          const figure = pre.ownerDocument.createElement('figure');
          figure.className = 'ticket-diagram';
          const picture = pre.ownerDocument.createElement('div');
          picture.className = 'diagram-picture';
          picture.innerHTML = sanitize(svg);
          const details = pre.ownerDocument.createElement('details');
          details.className = 'diagram-source';
          const summary = pre.ownerDocument.createElement('summary');
          summary.textContent = 'Mermaid source';
          details.append(summary);
          pre.replaceWith(figure);
          details.append(pre);
          figure.append(picture, details);
          pre.dataset.diagram = 'done';
        } catch (error) {
          if (!pre.isConnected) return;
          pre.dataset.diagram = 'error';
          const note = pre.ownerDocument.createElement('div');
          note.className = 'diagram-error';
          note.textContent = 'Diagram could not be rendered; Mermaid source is shown below.';
          pre.before(note);
        }
      });
    });
    return queue;
  }
  return { render };
});
