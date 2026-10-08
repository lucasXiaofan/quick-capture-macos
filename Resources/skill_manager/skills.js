// Pure helpers for the Skill Manager page (no DOM), so tests can run them in Node.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SkillUtil = api;
})(typeof self !== 'undefined' ? self : globalThis, function () {
  /// Splits "---\nkey: value\n---\nbody" into { meta, body }. Handles quoted values and
  /// folded/literal (> or |) or indented multi-line values. No front matter → meta is {}.
  function parseFrontmatter(text) {
    const m = /^---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(text || '');
    if (!m) return { meta: {}, body: text || '' };
    const meta = {};
    const lines = m[1].split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const kv = /^([A-Za-z0-9_-]+):\s*(.*)$/.exec(lines[i]);
      if (!kv) continue;
      let value = kv[2].trim();
      if (value === '' || value === '>' || value === '|' || value === '>-' || value === '|-') {
        const parts = [];
        while (i + 1 < lines.length && /^\s+\S/.test(lines[i + 1])) parts.push(lines[++i].trim());
        value = parts.join(value.startsWith('|') ? '\n' : ' ');
      }
      if (/^(['"]).*\1$/.test(value) && value.length >= 2) value = value.slice(1, -1);
      meta[kv[1]] = value;
    }
    return { meta, body: text.slice(m[0].length) };
  }

  /// Joins a relative path onto a folder ("references") and normalizes ./ and ../.
  /// Returns null when the path climbs above the skill root.
  function resolvePath(fromDir, rel) {
    const parts = (fromDir ? fromDir.split('/') : []).concat(rel.split('/'));
    const out = [];
    for (const p of parts) {
      if (p === '' || p === '.') continue;
      if (p === '..') { if (!out.length) return null; out.pop(); } else out.push(p);
    }
    return out.join('/');
  }

  function dirname(rel) {
    const i = rel.lastIndexOf('/');
    return i < 0 ? '' : rel.slice(0, i);
  }

  /// Finds which file of the skill a piece of text (a link href or `inline code`) refers to.
  /// Tries: relative to the current file, relative to the skill root, then a unique suffix match.
  function matchFile(text, currentRel, files) {
    let t = (text || '').trim().replace(/^[`("']+/, '').replace(/[`)"',.;:]+$/, '').split('#')[0];
    if (!t || /^[a-z]+:\/\//i.test(t) || t.length > 200 || /\s/.test(t)) return null;
    const set = new Set(files);
    const candidates = [resolvePath(dirname(currentRel || ''), t), resolvePath('', t)];
    for (const c of candidates) {
      if (!c) continue;
      if (set.has(c)) return c;
      // A folder ("references/") opens its first file.
      const inFolder = files.filter(f => f.startsWith(c + '/'));
      if (inFolder.length && /\/$|^[^.]+$/.test(t)) return inFolder[0];
    }
    if (t.includes('/') || /\.[a-z0-9]+$/i.test(t)) {
      const hits = files.filter(f => f === t || f.endsWith('/' + t));
      if (hits.length === 1) return hits[0];
    }
    return null;
  }

  /// Orders a skill's files: SKILL.md, other top-level files, then folders alphabetically.
  function sortFiles(files) {
    const rank = f => (f === 'SKILL.md' ? 0 : f.includes('/') ? 2 : 1);
    return files.slice().sort((a, b) => rank(a) - rank(b) || a.localeCompare(b));
  }

  /// A Markdown code fence longer than any backtick run inside `text`.
  function fence(text, lang) {
    const longest = Math.max(2, ...((text.match(/`+/g) || []).map(s => s.length)));
    const f = '`'.repeat(longest + 1);
    return f + (lang || '') + '\n' + text + '\n' + f;
  }

  const LANG = { py: 'python', sh: 'bash', zsh: 'bash', js: 'javascript', cjs: 'javascript', mjs: 'javascript',
    ts: 'typescript', yaml: 'yaml', yml: 'yaml', json: 'json', toml: 'ini', swift: 'swift', csv: 'plaintext', txt: 'plaintext' };

  function extension(rel) {
    const m = /\.([a-z0-9]+)$/i.exec(rel);
    return m ? m[1].toLowerCase() : '';
  }

  function language(rel) { return LANG[extension(rel)] || 'plaintext'; }

  /// "today", "yesterday", "3 days ago", "5 weeks ago", or a date.
  function ago(ms, now) {
    const days = Math.floor(((now || Date.now()) - ms) / 86400000);
    if (days <= 0) return 'today';
    if (days === 1) return 'yesterday';
    if (days < 14) return days + ' days ago';
    if (days < 60) return Math.round(days / 7) + ' weeks ago';
    return new Date(ms).toISOString().slice(0, 10);
  }

  const NAME_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

  return { parseFrontmatter, resolvePath, dirname, matchFile, sortFiles, fence, extension, language, ago, NAME_RE };
});
