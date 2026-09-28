// Markdown + LaTeX renderer for the chat. Pure (no DOM access) so tests can run it in Node.
//   $…$ and \(…\) inline math, $$…$$ and \[…\] display math; math inside code is left alone.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.QCRender = api;
})(typeof self !== 'undefined' ? self : globalThis, function () {
  function tex(katex, source, display) {
    try {
      return katex.renderToString(source, { displayMode: display, throwOnError: false, output: 'html', strict: 'ignore' });
    } catch (e) {
      return '<code class="math-error">' + escapeHtml(source) + '</code>';
    }
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  function mathExtensions(katex) {
    const block = {
      name: 'mathBlock',
      level: 'block',
      start(src) {
        const m = src.match(/^ {0,3}(?:\$\$|\\\[)/m);
        return m ? m.index : undefined;
      },
      tokenizer(src) {
        const m = /^ {0,3}(?:\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\])[ \t]*(?:\n+|$)/.exec(src);
        if (m) return { type: 'mathBlock', raw: m[0], text: (m[1] ?? m[2]).trim() };
      },
      renderer(token) {
        return '<div class="math-block">' + tex(katex, token.text, true) + '</div>\n';
      },
    };
    const inline = {
      name: 'math',
      level: 'inline',
      start(src) {
        const m = src.match(/\$|\\\(|\\\[/);
        return m ? m.index : undefined;
      },
      tokenizer(src) {
        let m;
        if ((m = /^\$\$(?!\$)([\s\S]+?)\$\$/.exec(src))) return { type: 'math', raw: m[0], text: m[1].trim(), display: true };
        if ((m = /^\\\[([\s\S]+?)\\\]/.exec(src))) return { type: 'math', raw: m[0], text: m[1].trim(), display: true };
        if ((m = /^\\\(([\s\S]+?)\\\)/.exec(src))) return { type: 'math', raw: m[0], text: m[1].trim(), display: false };
        // $x$: no space just inside the dollars and no digit right after (so "$5 and $10" stays text).
        if ((m = /^\$(?![\s$])((?:\\[\s\S]|[^\\$\n])+?)(?<![\s\\])\$(?!\d)/.exec(src))) {
          return { type: 'math', raw: m[0], text: m[1], display: false };
        }
      },
      renderer(token) {
        return token.display ? '<span class="math-display">' + tex(katex, token.text, true) + '</span>' : tex(katex, token.text, false);
      },
    };
    return [block, inline];
  }

  /// Returns render(markdown) → HTML string. `sanitize` (DOMPurify in the page) is optional.
  function createRenderer({ marked, katex, sanitize }) {
    const md = new marked.Marked({ gfm: true, breaks: false });
    md.use({ extensions: mathExtensions(katex) });
    return function render(src) {
      const html = md.parse(src || '');
      return sanitize ? sanitize(html) : html;
    };
  }

  return { createRenderer, escapeHtml };
});
