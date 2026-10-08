// Tests the Skill Manager page's pure helpers (front matter, path links, file order).
const assert = require('node:assert/strict');
const path = require('node:path');
const U = require(path.join(__dirname, '..', 'Resources', 'skill_manager', 'skills.js'));

const fm = U.parseFrontmatter('---\nname: agent-benchmark\ndescription: "Use: when x"\n---\n# Body\n');
assert.equal(fm.meta.name, 'agent-benchmark');
assert.equal(fm.meta.description, 'Use: when x');
assert.equal(fm.body, '# Body\n');
const folded = U.parseFrontmatter('---\nname: a\ndescription: >\n  line one\n  line two\n---\nx');
assert.equal(folded.meta.description, 'line one line two');
assert.deepEqual(U.parseFrontmatter('# no front matter').meta, {});

assert.equal(U.resolvePath('references', '../SKILL.md'), 'SKILL.md');
assert.equal(U.resolvePath('', './a/b.md'), 'a/b.md');
assert.equal(U.resolvePath('', '../x'), null);

const files = ['SKILL.md', 'references/evaluation.md', 'references/data.md', 'templates/dim.yaml', 'scripts/new_exp.sh'];
assert.equal(U.matchFile('references/evaluation.md', 'SKILL.md', files), 'references/evaluation.md');
assert.equal(U.matchFile('`references/data.md`).', 'SKILL.md', files), 'references/data.md');
assert.equal(U.matchFile('evaluation.md', 'references/data.md', files), 'references/evaluation.md');
assert.equal(U.matchFile('../SKILL.md#rules', 'references/data.md', files), 'SKILL.md');
assert.equal(U.matchFile('templates/', 'SKILL.md', files), 'templates/dim.yaml');
assert.equal(U.matchFile('dim.yaml', 'SKILL.md', files), 'templates/dim.yaml');
assert.equal(U.matchFile('src/bench/paths.py', 'SKILL.md', files), null);
assert.equal(U.matchFile('https://x.org/a.md', 'SKILL.md', files), null);
assert.equal(U.matchFile('uv run python -m x', 'SKILL.md', files), null);

assert.deepEqual(U.sortFiles(['templates/a.md', 'README.md', 'SKILL.md', 'references/b.md']),
  ['SKILL.md', 'README.md', 'references/b.md', 'templates/a.md']);
assert.equal(U.fence('a ``` b', 'md'), '````md\na ``` b\n````');
assert.equal(U.language('x/run.sh'), 'bash');
assert.equal(U.ago(Date.now()), 'today');
assert.ok(U.NAME_RE.test('agent-benchmark') && !U.NAME_RE.test('Agent_Benchmark') && !U.NAME_RE.test('a--b'));
console.log('skills.test: all passed');
