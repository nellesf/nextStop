'use strict';

const { globSync: findFiles, hasMagic } = require('glob');

// Only typescript-estree 8.67.0's resolveProjectList uses this adapter. Keeping
// the override scoped and rejecting new options makes upstream API drift fail.
// This removes picomatch (GHSA-fc5q-39xc-vjpf); it is not a renamed fork of it.
function isDynamicPattern(pattern) {
  if (typeof pattern !== 'string') throw new TypeError('Expected a project pattern');
  return pattern.startsWith('!') || pattern.includes('\\') || pattern.includes('(')
    || hasMagic(pattern, { magicalBraces: true, nonegate: true, nocomment: true });
}

function globSync(pattern, options) {
  if (typeof pattern !== 'string') throw new TypeError('Expected a project pattern');
  if (!options || options.expandDirectories !== false) {
    throw new TypeError('Project globbing requires expandDirectories: false');
  }
  for (const key of Object.keys(options)) {
    if (!['cwd', 'expandDirectories', 'ignore'].includes(key)) {
      throw new TypeError(`Unsupported project glob option: ${key}`);
    }
  }
  const ignore = options.ignore ?? [];
  if (!Array.isArray(ignore) || ignore.some(value => typeof value !== 'string')) {
    throw new TypeError('Expected an array of ignored project patterns');
  }
  // A standalone exclusion has no positive pattern to match. A leading !(
  // remains an extglob, as it does in tinyglobby.
  if (pattern.startsWith('!') && !pattern.startsWith('!(')) return [];
  return findFiles(pattern, {
    cwd: options.cwd,
    ignore,
    nodir: true,
    dot: false,
    nocase: false,
    follow: true,
    nonegate: true,
    nocomment: true,
  }).sort();
}

module.exports = { isDynamicPattern, globSync };
