#!/usr/bin/env node
/* Migrate legacy npm-reorg-guard state into the safedeps namespace. */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const legacyRoot = process.env.SAFEDEPS_LEGACY_HOME || path.join(os.homedir(), '.npm-reorg-guard');
const targetRoot = process.env.SAFEDEPS_HOME || path.join(os.homedir(), '.safedeps');
const keepLegacy = process.argv.includes('--keep-legacy');

function stamp() {
  return new Date().toISOString().replaceAll(':', '').replaceAll('.', '').replace('Z', 'Z');
}

function uniqueArchivePath(base) {
  let candidate = `${base}.migrated-${stamp()}`;
  let i = 1;
  while (fs.existsSync(candidate)) {
    candidate = `${base}.migrated-${stamp()}-${i}`;
    i += 1;
  }
  return candidate;
}

function walk(root) {
  const out = [];
  if (!fs.existsSync(root)) return out;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const abs = path.join(root, entry.name);
    if (entry.isDirectory()) {
      out.push(...walk(abs));
    } else if (entry.isFile() || entry.isSymbolicLink()) {
      out.push(abs);
    }
  }
  return out;
}

function migrate() {
  if (!fs.existsSync(legacyRoot)) {
    return { migrated: false, reason: 'legacy_missing', legacyRoot, targetRoot, copied: 0, skipped: 0 };
  }

  fs.mkdirSync(targetRoot, { recursive: true, mode: 0o700 });

  let copied = 0;
  let skipped = 0;
  const skippedPaths = [];
  for (const source of walk(legacyRoot)) {
    const rel = path.relative(legacyRoot, source);
    const target = path.join(targetRoot, rel);
    if (fs.existsSync(target)) {
      skipped += 1;
      skippedPaths.push(rel);
      continue;
    }
    fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
    fs.copyFileSync(source, target);
    try {
      fs.chmodSync(target, fs.statSync(source).mode & 0o777);
    } catch {
      fs.chmodSync(target, 0o600);
    }
    copied += 1;
  }

  let archivedAs = null;
  if (!keepLegacy) {
    archivedAs = uniqueArchivePath(legacyRoot);
    fs.renameSync(legacyRoot, archivedAs);
  }

  return {
    migrated: true,
    legacyRoot,
    targetRoot,
    copied,
    skipped,
    skippedPaths,
    archivedAs,
    keptLegacy: keepLegacy
  };
}

try {
  console.log(JSON.stringify(migrate(), null, 2));
} catch (error) {
  console.error(`safedeps migrate: ${error.message}`);
  process.exit(1);
}
