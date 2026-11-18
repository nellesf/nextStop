// Exercise the real TypeScript ESLint consumer after removing its picomatch tree.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { createRequire } = require('node:module');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const backendDirectory = path.resolve(__dirname, '../../backend');
const backend = createRequire(path.join(backendDirectory, 'package.json'));
const estreeDirectory = path.dirname(backend.resolve('@typescript-eslint/typescript-estree/package.json'));
const estree = createRequire(path.join(estreeDirectory, 'package.json'));
const adapterPath = estree.resolve('tinyglobby');
const { globSync, isDynamicPattern } = estree('tinyglobby');
const { resolveProjectList, clearGlobResolutionCache } = require(path.join(
  estreeDirectory, 'dist/parseSettings/resolveProjectList.js'));
const { clearCaches } = require(path.join(estreeDirectory, 'dist/clear-caches.js'));

function fixture(t, files) {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'nextstop-project-glob-'));
  t.after(() => fs.rmSync(cwd, { recursive: true, force: true }));
  for (const [name, content] of Object.entries(files)) {
    const file = path.join(cwd, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
  }
  return cwd;
}

test('the installed parser resolves the replacement and the lock contains no picomatch', () => {
  assert.equal(fs.realpathSync(adapterPath), fs.realpathSync(path.join(
    backendDirectory, 'tools/typescript-project-glob/index.cjs')));
  const lock = JSON.parse(fs.readFileSync(path.join(backendDirectory, 'package-lock.json'), 'utf8'));
  assert.deepEqual(Object.keys(lock.packages).filter(name => /(?:^|\/)node_modules\/picomatch$/.test(name)), []);
});

test('project glob detection distinguishes literals and expansions', () => {
  for (const pattern of ['tsconfig.json', 'packages/app/tsconfig.json']) {
    assert.equal(isDynamicPattern(pattern), false, pattern);
  }
  for (const pattern of ['**/tsconfig.json', 'packages/{a,b}/tsconfig.json', 'packages/+(a|b)/tsconfig.json']) {
    assert.equal(isDynamicPattern(pattern), true, pattern);
  }
});

test('the real project resolver preserves pattern precedence, deduplicates, and ignores node_modules', t => {
  const cwd = fixture(t, {
    'packages/a/tsconfig.main.json': '{}',
    'packages/b/tsconfig.main.json': '{}',
    'packages/a/node_modules/vendor/tsconfig.main.json': '{}',
  });
  try {
    const projects = resolveProjectList({
      project: ['packages/b/tsconfig.*.json', 'packages/a/tsconfig.*.json', 'packages/**/tsconfig.*.json'],
      tsconfigRootDir: cwd,
      singleRun: true,
    });
    assert.deepEqual([...projects.values()], [
      path.join(cwd, 'packages/b/tsconfig.main.json'),
      path.join(cwd, 'packages/a/tsconfig.main.json'),
    ]);
  } finally {
    clearGlobResolutionCache();
  }
});

test('project discovery returns files, follows symlinks, and respects dotfiles, case, and ignores', t => {
  const cwd = fixture(t, {
    'packages/app/tsconfig.json': '{}',
    'packages/skip/tsconfig.json': '{}',
    '.hidden/tsconfig.json': '{}',
    'packages/upper/TSCONFIG.JSON': '{}',
  });
  fs.mkdirSync(path.join(cwd, 'directory/tsconfig.json'), { recursive: true });
  fs.symlinkSync('packages/app', path.join(cwd, 'linked'), 'dir');
  const options = { cwd, expandDirectories: false, ignore: ['**/skip/**'] };
  assert.deepEqual(globSync('**/tsconfig.json', options).sort(), [
    'linked/tsconfig.json', 'packages/app/tsconfig.json',
  ]);
  assert.deepEqual(globSync('packages/app', options), []);
  assert.deepEqual(globSync('packages/{app,skip}/tsconfig.json', options), ['packages/app/tsconfig.json']);
});

test('the real resolver handles escaped special characters in project paths', t => {
  const cwd = fixture(t, { 'packages/(app)/tsconfig.json': '{}' });
  try {
    const projects = resolveProjectList({
      project: ['packages/\\(app\\)/tsconfig.json'],
      tsconfigRootDir: cwd,
      singleRun: true,
    });
    assert.deepEqual([...projects.values()], [path.join(cwd, 'packages/(app)/tsconfig.json')]);
  } finally {
    clearGlobResolutionCache();
  }
});

test('globbed parserOptions.project produces actual TypeScript type information', t => {
  const source = 'export const count: number = 1;';
  const cwd = fixture(t, {
    'packages/app/tsconfig.json': JSON.stringify({
      compilerOptions: { strict: true, noLib: true }, include: ['*.ts'],
    }),
    'packages/app/index.ts': source,
  });
  try {
    const { ast, services } = backend('@typescript-eslint/typescript-estree').parseAndGenerateServices(source, {
      filePath: path.join(cwd, 'packages/app/index.ts'),
      project: ['packages/*/tsconfig.json'],
      tsconfigRootDir: cwd,
      sourceType: 'module',
    });
    assert.ok(services.program);
    const identifier = ast.body[0].declaration.declarations[0].id;
    const checker = services.program.getTypeChecker();
    assert.equal(checker.typeToString(checker.getTypeAtLocation(
      services.esTreeNodeToTSNodeMap.get(identifier))), 'number');
  } finally {
    clearCaches();
  }
});

test('unsupported consumer options fail explicitly', () => {
  assert.throws(() => globSync('**/tsconfig.json', { expandDirectories: true }), TypeError);
  assert.throws(() => globSync('**/tsconfig.json', { expandDirectories: false, dot: true }), TypeError);
});

test('single-branch repeated extglobs complete within a separate process deadline', t => {
  const cwd = fixture(t, {
    ['a'.repeat(40) + '!/tsconfig.json']: '{}',
    ['ab'.repeat(35) + '!/tsconfig.json']: '{}',
  });
  const result = spawnSync(process.execPath, ['-e', `
    const assert = require('node:assert/strict');
    const { globSync } = require(process.argv[1]);
    for (const pattern of ['+(*a)/tsconfig.json', '*(*a)/tsconfig.json', '+(ab|abab)/tsconfig.json']) {
      assert.deepEqual(globSync(pattern, { cwd: process.argv[2], expandDirectories: false }), []);
    }
    console.log('completed');
  `, adapterPath, cwd], { encoding: 'utf8', timeout: 5000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), 'completed');
});
