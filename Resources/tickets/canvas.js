// A small JSON Canvas (the format Obsidian uses) viewer and editor: cards, groups, images and arrows on an
// endless board you pan and zoom. It edits the canvas object in place, so fields it doesn't know survive.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.TKCanvas = api;
})(typeof self !== 'undefined' ? self : globalThis, function () {
  const COLORS = { 1: '#e5484d', 2: '#f08c2e', 3: '#d9a900', 4: '#2fa968', 5: '#19a5c8', 6: '#8e62e8' };
  const colorOf = c => (c == null || c === '') ? '' : COLORS[c] || (/^#[0-9a-f]{3,8}$/i.test(String(c)) ? String(c) : '');
  const SIDES = { top: [0.5, 0, 0, -1], right: [1, 0.5, 1, 0], bottom: [0.5, 1, 0, 1], left: [0, 0.5, -1, 0] };
  const num = (v, fallback = 0) => (typeof v === 'number' && isFinite(v) ? v : fallback);

  function anchor(node, side) {
    const s = SIDES[side] || SIDES.right;
    return { x: num(node.x) + num(node.width) * s[0], y: num(node.y) + num(node.height) * s[1], nx: s[2], ny: s[3] };
  }

  /// The sides two nodes should be joined by when an edge doesn't say.
  function autoSides(a, b) {
    const dx = (b.x + b.width / 2) - (a.x + a.width / 2), dy = (b.y + b.height / 2) - (a.y + a.height / 2);
    if (Math.abs(dx) > Math.abs(dy)) return dx > 0 ? ['right', 'left'] : ['left', 'right'];
    return dy > 0 ? ['bottom', 'top'] : ['top', 'bottom'];
  }

  function nearestSide(node, x, y) {
    const d = { left: Math.abs(x - node.x), right: Math.abs(x - node.x - node.width), top: Math.abs(y - node.y), bottom: Math.abs(y - node.y - node.height) };
    return Object.keys(d).sort((p, q) => d[p] - d[q])[0];
  }

  /// A curve from a to b leaving along each side's normal: { d, mid, end: { x, y, angle } }.
  function edgeGeometry(a, b) {
    const reach = Math.max(30, Math.min(140, Math.hypot(b.x - a.x, b.y - a.y) / 2));
    const c1 = { x: a.x + a.nx * reach, y: a.y + a.ny * reach }, c2 = { x: b.x + b.nx * reach, y: b.y + b.ny * reach };
    const at = t => {
      const u = 1 - t;
      return { x: u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x,
        y: u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y };
    };
    return { d: `M${a.x},${a.y} C${c1.x},${c1.y} ${c2.x},${c2.y} ${b.x},${b.y}`, mid: at(0.5),
      end: { x: b.x, y: b.y, angle: Math.atan2(-b.ny, -b.nx) }, start: { x: a.x, y: a.y, angle: Math.atan2(-a.ny, -a.nx) } };
  }

  function bounds(canvas) {
    const nodes = (canvas.nodes || []).filter(n => typeof n.x === 'number');
    if (!nodes.length) return { x: 0, y: 0, width: 0, height: 0 };
    const x0 = Math.min(...nodes.map(n => n.x)), y0 = Math.min(...nodes.map(n => n.y));
    const x1 = Math.max(...nodes.map(n => n.x + num(n.width))), y1 = Math.max(...nodes.map(n => n.y + num(n.height)));
    return { x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
  }

  const newID = () => Array.from({ length: 16 }, () => Math.floor(Math.random() * 16).toString(16)).join('');
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const snap = v => Math.round(v / 10) * 10;

  /// opts: readOnly, render(text) → HTML for a card, assetURL(path) → URL of an image, onChange(canvas), onSelect(selection)
  function mount(host, canvas, opts = {}) {
    canvas.nodes = Array.isArray(canvas.nodes) ? canvas.nodes : [];
    canvas.edges = Array.isArray(canvas.edges) ? canvas.edges : [];
    const ro = !!opts.readOnly;
    const render = opts.render || (text => esc(text).replace(/\n/g, '<br>'));
    host.classList.add('cv');
    host.classList.toggle('cv-ro', ro);
    host.tabIndex = 0;
    host.innerHTML = '<div class="cv-world"><div class="cv-nodes"></div><svg class="cv-edges" width="1" height="1"><g></g></svg><div class="cv-labels"></div></div><div class="cv-empty" hidden></div>';
    const world = host.querySelector('.cv-world'), nodesBox = host.querySelector('.cv-nodes'), edgeLayer = host.querySelector('.cv-edges g'),
      labels = host.querySelector('.cv-labels'), emptyNote = host.querySelector('.cv-empty');
    const view = { x: 0, y: 0, z: 1 };
    let sel = null;        // { type: 'node' | 'edge', id }
    let editing = null;    // { type, id, el }
    let drag = null;
    let ghost = null;      // the line being drawn while connecting
    const history = [];

    const node = id => canvas.nodes.find(n => n.id === id);
    const edge = id => canvas.edges.find(e => e.id === id);
    const toWorld = e => { const r = host.getBoundingClientRect(); return { x: (e.clientX - r.left - view.x) / view.z, y: (e.clientY - r.top - view.y) / view.z }; };

    function applyView() {
      world.style.transform = `translate(${view.x}px, ${view.y}px) scale(${view.z})`;
      const grid = 20 * view.z;
      host.style.backgroundSize = grid >= 8 ? `${grid}px ${grid}px` : '0 0';
      host.style.backgroundPosition = `${view.x}px ${view.y}px`;
      if (opts.onView) opts.onView(view);
    }

    function fit() {
      const b = bounds(canvas), w = host.clientWidth || 900, h = host.clientHeight || 600;
      if (!b.width && !b.height) { view.x = w / 2; view.y = h / 2; view.z = 1; return applyView(); }
      view.z = Math.max(0.08, Math.min(1, (w - 80) / b.width, (h - 80) / b.height));
      view.x = (w - b.width * view.z) / 2 - b.x * view.z;
      view.y = (h - b.height * view.z) / 2 - b.y * view.z;
      applyView();
    }

    function zoomAt(factor, cx, cy) {
      const z = Math.max(0.08, Math.min(3, view.z * factor));
      view.x = cx - (cx - view.x) * (z / view.z);
      view.y = cy - (cy - view.y) * (z / view.z);
      view.z = z;
      applyView();
    }

    function place(el, n) {
      el.style.left = num(n.x) + 'px'; el.style.top = num(n.y) + 'px';
      el.style.width = num(n.width, 250) + 'px'; el.style.height = num(n.height, 60) + 'px';
    }

    function nodeHTML(n) {
      const c = colorOf(n.color);
      const selected = sel && sel.type === 'node' && sel.id === n.id;
      let body;
      if (n.type === 'group') body = `<div class="cv-label">${esc(n.label || '')}</div>`;
      else if (n.type === 'file') {
        const path = String(n.file || ''), image = /\.(png|jpe?g|gif|webp|svg|avif|bmp)$/i.test(path);
        body = image && opts.assetURL ? `<img src="${esc(opts.assetURL(path))}" alt="" draggable="false">` : `<div class="cv-body">📎 ${esc(path.split('/').pop())}</div>`;
      } else if (n.type === 'link') body = `<div class="cv-body"><a href="${esc(n.url || '')}">${esc(n.url || '')}</a></div>`;
      else body = `<div class="cv-body md">${render(n.text || '')}</div>`;
      const tools = ro ? '' : Object.keys(SIDES).map(s => `<i class="cv-port ${s}" data-side="${s}"></i>`).join('') + '<i class="cv-resize"></i>';
      return `<div class="cv-node ${esc(n.type || 'text')} ${selected ? 'sel' : ''} ${c ? 'tinted' : ''}" data-id="${esc(n.id)}" ${c ? `style="--c:${c}"` : ''}>${body}${tools}</div>`;
    }

    function drawNodes() {
      // Groups sit below everything else, big ones lowest.
      const groups = canvas.nodes.filter(n => n.type === 'group').sort((a, b) => num(b.width) * num(b.height) - num(a.width) * num(a.height));
      const rest = canvas.nodes.filter(n => n.type !== 'group');
      nodesBox.innerHTML = [...groups, ...rest].map(nodeHTML).join('');
      nodesBox.querySelectorAll('.cv-node').forEach(el => place(el, node(el.dataset.id)));
      emptyNote.hidden = canvas.nodes.length > 0;
      emptyNote.textContent = ro ? 'Nothing to show.' : 'Double-click anywhere to add a card.';
    }

    function arrow(p, colour) {
      const size = 9, a = p.angle, wing = 0.45;
      const pt = t => `${p.x - size * Math.cos(a + t)},${p.y - size * Math.sin(a + t)}`;
      return `<polygon points="${p.x},${p.y} ${pt(wing)} ${pt(-wing)}" fill="${colour}"/>`;
    }

    function drawEdges() {
      let svg = '', html = '';
      for (const e of canvas.edges) {
        const from = node(e.fromNode), to = node(e.toNode);
        if (!from || !to) continue;
        const [fs, ts] = e.fromSide && e.toSide ? [e.fromSide, e.toSide] : autoSides(from, to);
        const g = edgeGeometry(anchor(from, e.fromSide || fs), anchor(to, e.toSide || ts));
        const colour = colorOf(e.color) || 'var(--cv-line)';
        const selected = sel && sel.type === 'edge' && sel.id === e.id;
        svg += `<g class="cv-edge ${selected ? 'sel' : ''}" data-edge="${esc(e.id)}"><path class="hit" d="${g.d}"/><path class="line" d="${g.d}" stroke="${colour}"/>`
          + (e.toEnd === 'none' ? '' : arrow(g.end, colour)) + (e.fromEnd === 'arrow' ? arrow(g.start, colour) : '') + '</g>';
        if (e.label || (editing && editing.type === 'edge' && editing.id === e.id)) {
          html += `<div class="cv-edge-label ${selected ? 'sel' : ''}" data-edge="${esc(e.id)}" style="left:${g.mid.x}px;top:${g.mid.y}px">${esc(e.label || '')}</div>`;
        }
      }
      if (ghost) svg += `<path class="line ghost" d="M${ghost.a.x},${ghost.a.y} L${ghost.b.x},${ghost.b.y}"/>`;
      edgeLayer.innerHTML = svg;
      labels.innerHTML = html;
    }

    function draw() { drawNodes(); drawEdges(); }

    function select(next) {
      const same = (sel && next && sel.type === next.type && sel.id === next.id) || (!sel && !next);
      sel = next;
      if (!same) { draw(); if (opts.onSelect) opts.onSelect(selection()); }
    }

    function selection() {
      if (!sel) return null;
      const item = sel.type === 'node' ? node(sel.id) : edge(sel.id);
      return item ? { type: sel.type, id: sel.id, color: item.color == null ? '' : String(item.color), kind: item.type || '' } : null;
    }

    const remember = () => { history.push(JSON.stringify({ nodes: canvas.nodes, edges: canvas.edges })); if (history.length > 60) history.shift(); };
    const changed = () => { if (opts.onChange) opts.onChange(canvas); };

    function undo() {
      const last = history.pop();
      if (!last) return;
      const state = JSON.parse(last);
      canvas.nodes = state.nodes; canvas.edges = state.edges;
      sel = null; editing = null;
      draw(); changed();
      if (opts.onSelect) opts.onSelect(null);
    }

    function remove() {
      if (ro || !sel) return;
      remember();
      if (sel.type === 'node') {
        canvas.nodes = canvas.nodes.filter(n => n.id !== sel.id);
        canvas.edges = canvas.edges.filter(e => e.fromNode !== sel.id && e.toNode !== sel.id);
      } else canvas.edges = canvas.edges.filter(e => e.id !== sel.id);
      sel = null;
      draw(); changed();
      if (opts.onSelect) opts.onSelect(null);
    }

    function add(type, at) {
      if (ro) return;
      const centre = at || { x: ((host.clientWidth || 900) / 2 - view.x) / view.z, y: ((host.clientHeight || 600) / 2 - view.y) / view.z };
      remember();
      const n = type === 'group'
        ? { id: newID(), type: 'group', label: 'Group', x: snap(centre.x - 200), y: snap(centre.y - 150), width: 400, height: 300 }
        : { id: newID(), type: 'text', text: '', x: snap(centre.x - 130), y: snap(centre.y - 40), width: 260, height: 80 };
      canvas.nodes.push(n);
      sel = { type: 'node', id: n.id };
      draw(); changed();
      if (opts.onSelect) opts.onSelect(selection());
      edit({ type: 'node', id: n.id });
    }

    function setColor(c) {
      if (ro || !sel) return;
      const item = sel.type === 'node' ? node(sel.id) : edge(sel.id);
      if (!item) return;
      remember();
      if (c) item.color = String(c); else delete item.color;
      draw(); changed();
      if (opts.onSelect) opts.onSelect(selection());
    }

    // MARK: Editing text in place

    function edit(target) {
      if (ro) return;
      commitEdit();
      if (target.type === 'node') {
        const n = node(target.id), el = nodesBox.querySelector(`[data-id="${CSS.escape(target.id)}"]`);
        if (!n || !el || (n.type !== 'text' && n.type !== 'group')) return;
        const field = host.ownerDocument.createElement(n.type === 'group' ? 'input' : 'textarea');
        field.className = 'cv-edit';
        field.value = n.type === 'group' ? (n.label || '') : (n.text || '');
        (el.querySelector('.cv-body') || el.querySelector('.cv-label')).replaceWith(field);
        editing = { ...target, el: field };
      } else {
        const e = edge(target.id);
        if (!e) return;
        editing = { ...target, el: null };
        drawEdges();
        const label = labels.querySelector(`[data-edge="${CSS.escape(target.id)}"]`);
        if (!label) { editing = null; return; }
        const field = host.ownerDocument.createElement('input');
        field.className = 'cv-edit';
        field.value = e.label || '';
        field.placeholder = 'label';
        label.textContent = '';
        label.append(field);
        editing.el = field;
      }
      const field = editing.el;
      field.focus();
      if (field.select && target.type === 'edge') field.select();
      field.addEventListener('blur', commitEdit);
      field.addEventListener('keydown', e => {
        e.stopPropagation();
        if (e.key === 'Escape' || (e.key === 'Enter' && (field.tagName === 'INPUT' || e.metaKey))) { e.preventDefault(); commitEdit(); host.focus(); }
      });
    }

    function commitEdit() {
      if (!editing) return;
      const { type, id, el } = editing;
      editing = null;
      const value = el ? el.value : '';
      if (type === 'node') {
        const n = node(id);
        if (n) {
          const key = n.type === 'group' ? 'label' : 'text';
          if ((n[key] || '') !== value) { remember(); n[key] = value; changed(); }
        }
      } else {
        const e = edge(id);
        if (e && (e.label || '') !== value.trim()) { remember(); if (value.trim()) e.label = value.trim(); else delete e.label; changed(); }
      }
      draw();
    }

    // MARK: Pointer

    host.addEventListener('pointerdown', e => {
      if (e.button !== 0 || e.target.closest('.cv-edit')) return;
      if (e.target.closest('a')) return;
      commitEdit();
      const p = toWorld(e);
      const port = e.target.closest('.cv-port'), grip = e.target.closest('.cv-resize');
      const nodeEl = e.target.closest('.cv-node'), edgeEl = e.target.closest('[data-edge]');
      const pan = () => { drag = { kind: 'pan', sx: e.clientX, sy: e.clientY, vx: view.x, vy: view.y }; };
      if (nodeEl && !ro && port) {
        const n = node(nodeEl.dataset.id);
        drag = { kind: 'connect', from: n.id, side: port.dataset.side };
        ghost = { a: anchor(n, port.dataset.side), b: p };
      } else if (nodeEl && !ro && grip) {
        const n = node(nodeEl.dataset.id);
        select({ type: 'node', id: n.id });
        drag = { kind: 'resize', id: n.id, p, w: n.width, h: n.height, moved: false };
      } else if (nodeEl) {
        const n = node(nodeEl.dataset.id);
        select({ type: 'node', id: n.id });
        if (ro) pan();
        else {
          // A group carries what lies inside it.
          const inside = n.type !== 'group' ? [] : canvas.nodes.filter(o => o !== n && o.x >= n.x && o.y >= n.y && o.x + o.width <= n.x + n.width && o.y + o.height <= n.y + n.height);
          drag = { kind: 'move', p, items: [n, ...inside].map(o => ({ node: o, x: o.x, y: o.y })), moved: false };
        }
      } else if (edgeEl) {
        select({ type: 'edge', id: edgeEl.dataset.edge });
      } else {
        select(null);
        pan();
      }
      if (drag) { try { host.setPointerCapture(e.pointerId); } catch (err) { /* synthetic event */ } }
      if (!e.target.closest('input, textarea')) { e.preventDefault(); host.focus({ preventScroll: true }); }
    });

    host.addEventListener('pointermove', e => {
      if (!drag) return;
      const p = toWorld(e);
      if (drag.kind === 'pan') {
        view.x = drag.vx + e.clientX - drag.sx; view.y = drag.vy + e.clientY - drag.sy;
        host.classList.add('panning');
        applyView();
      } else if (drag.kind === 'move') {
        const dx = p.x - drag.p.x, dy = p.y - drag.p.y;
        if (!drag.moved && Math.hypot(dx, dy) * view.z < 3) return;
        if (!drag.moved) { remember(); drag.moved = true; }
        for (const it of drag.items) {
          it.node.x = snap(it.x + dx); it.node.y = snap(it.y + dy);
          const el = nodesBox.querySelector(`[data-id="${CSS.escape(it.node.id)}"]`);
          if (el) place(el, it.node);
        }
        drawEdges();
      } else if (drag.kind === 'resize') {
        const n = node(drag.id);
        if (!drag.moved) { remember(); drag.moved = true; }
        n.width = Math.max(80, snap(drag.w + p.x - drag.p.x)); n.height = Math.max(40, snap(drag.h + p.y - drag.p.y));
        const el = nodesBox.querySelector(`[data-id="${CSS.escape(n.id)}"]`);
        if (el) place(el, n);
        drawEdges();
      } else if (drag.kind === 'connect') {
        ghost.b = p;
        drawEdges();
      }
    });

    const release = e => {
      if (!drag) return;
      const done = drag;
      drag = null;
      host.classList.remove('panning');
      if (done.kind === 'connect') {
        ghost = null;
        const p = toWorld(e);
        // The topmost card under the pointer; a group only when no card is.
        const hit = canvas.nodes.filter(n => n.id !== done.from && p.x >= n.x && p.x <= n.x + n.width && p.y >= n.y && p.y <= n.y + n.height)
          .sort((a, b) => (a.type === 'group') - (b.type === 'group') || a.width * a.height - b.width * b.height)[0];
        if (hit) {
          remember();
          const made = { id: newID(), fromNode: done.from, fromSide: done.side, toNode: hit.id, toSide: nearestSide(hit, p.x, p.y) };
          canvas.edges.push(made);
          sel = { type: 'edge', id: made.id };
          changed();
          if (opts.onSelect) opts.onSelect(selection());
        }
        draw();
      } else if ((done.kind === 'move' || done.kind === 'resize') && done.moved) {
        changed();
      }
    };
    host.addEventListener('pointerup', release);
    host.addEventListener('pointercancel', release);

    host.addEventListener('dblclick', e => {
      if (ro || e.target.closest('.cv-edit')) return;
      const nodeEl = e.target.closest('.cv-node'), edgeEl = e.target.closest('[data-edge]');
      if (nodeEl) edit({ type: 'node', id: nodeEl.dataset.id });
      else if (edgeEl) edit({ type: 'edge', id: edgeEl.dataset.edge });
      else add('text', toWorld(e));
    });

    host.addEventListener('wheel', e => {
      if (e.target.closest('.cv-edit')) return;
      e.preventDefault();
      const r = host.getBoundingClientRect();
      if (e.ctrlKey || e.metaKey) zoomAt(Math.exp(-e.deltaY * 0.01), e.clientX - r.left, e.clientY - r.top);
      else { view.x -= e.deltaX; view.y -= e.deltaY; applyView(); }
    }, { passive: false });

    host.addEventListener('keydown', e => {
      if (editing) return;
      if ((e.key === 'Backspace' || e.key === 'Delete') && sel) { e.preventDefault(); remove(); }
      else if (e.key === 'z' && e.metaKey && !ro) { e.preventDefault(); undo(); }
      else if (e.key === 'Enter' && sel && !ro) { e.preventDefault(); edit(sel); }
      else if (e.key === 'Escape') select(null);
    });

    draw();
    fit();
    return {
      canvas, fit, add, remove, undo, setColor, selection,
      zoomBy: factor => zoomAt(factor, (host.clientWidth || 900) / 2, (host.clientHeight || 600) / 2),
      zoom: () => view.z,
      flush: commitEdit,
      destroy() { commitEdit(); host.innerHTML = ''; host.classList.remove('cv'); },
    };
  }

  return { COLORS, colorOf, anchor, autoSides, nearestSide, edgeGeometry, bounds, mount };
});
