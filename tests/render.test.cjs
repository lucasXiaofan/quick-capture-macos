// Tests the chat's Markdown + LaTeX renderer with the vendored libraries (no browser needed).
const assert = require('node:assert/strict');
const path = require('node:path');
const dir = path.join(__dirname, '..', 'Resources', 'ai_chat');
const marked = require(path.join(dir, 'vendor', 'marked.umd.js'));
const katex = require(path.join(dir, 'vendor', 'katex', 'katex.min.js'));
const { createRenderer } = require(path.join(dir, 'render.js'));
const render = createRenderer({ marked, katex });

const cases = [
  ['inline $…$', 'Energy $E=mc^2$ here', h => h.includes('class="katex"') && h.includes('<p>Energy ')],
  ['inline \\(…\\)', 'So \\(a^2+b^2\\) holds', h => h.includes('class="katex"') && !h.includes('\\(')],
  ['display $$…$$ block', 'Sum:\n\n$$\n\\sum_{i=1}^n i\n$$\n\nDone', h => h.includes('class="math-block"') && h.includes('katex-display')],
  ['display \\[…\\] block', '\\[\n\\int_0^1 x\\,dx\n\\]', h => h.includes('class="math-block"')],
  ['display right after a paragraph line', 'Result:\n$$x=1$$', h => h.includes('katex-display')],
  ['currency stays text', 'It costs $5 and $10 today', h => !h.includes('katex') && h.includes('$5 and $10')],
  ['math in inline code untouched', 'Use `$x$` literally', h => h.includes('<code>$x$</code>') && !h.includes('katex')],
  ['math in code block untouched', '```\n$$a$$ and $b$\n```', h => h.includes('$$a$$ and $b$') && !h.includes('katex')],
  ['escaped dollar', 'Price \\$5 not math $', h => !h.includes('katex')],
  ['links kept', 'See [main](Sources/App/main.swift:12) and https://example.com', h =>
    h.includes('href="Sources/App/main.swift:12"') && h.includes('href="https://example.com"')],
  ['gfm table', '| a | b |\n|---|---|\n| $x$ | 2 |', h => h.includes('<table>') && h.includes('katex')],
  ['bad tex does not throw', '$\\frac{1}{$', h => typeof h === 'string'],
  ['unclosed math while streaming', 'Partial $$\\alpha', h => !h.includes('katex-display')],
];

let failed = 0;
for (const [name, src, check] of cases) {
  const html = render(src);
  try { assert.ok(check(html)); } catch (e) { failed++; console.error(`✗ ${name}\n  ${JSON.stringify(src)}\n  → ${html}`); }
}
if (failed) { process.exitCode = 1; } else { console.log(`${cases.length} render tests passed: inline/display math, currency, code, links, tables`); }
