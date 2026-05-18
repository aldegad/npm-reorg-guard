#!/usr/bin/env node
// safedeps cross-engine installer.
// Registers the safedeps skill + PreToolUse/PostToolUse hooks for both
// Claude Code (~/.claude) and Codex CLI (~/.codex).
//
// Idempotent: running twice leaves state unchanged.
// Backup-before-write: every JSON config file is copied to .bak before edit.
//
// Usage:
//   node scripts/install/install-safedeps-hooks.mjs
//   node scripts/install/install-safedeps-hooks.mjs --uninstall
//   node scripts/install/install-safedeps-hooks.mjs --link-bin   (optional ~/.local/bin/safedeps)

import { existsSync, lstatSync, readFileSync, writeFileSync, copyFileSync, mkdirSync, symlinkSync, unlinkSync, readlinkSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..");
const HOME = homedir();

const SKILL_ID = "safedeps";
const PRE_HOOK = join(REPO_ROOT, "scripts", "safedeps-pre-guard.sh");
const POST_HOOK = join(REPO_ROOT, "scripts", "safedeps-post-verify.sh");
const CLI_BIN = join(REPO_ROOT, "bin", "safedeps");

const args = new Set(process.argv.slice(2));
const UNINSTALL = args.has("--uninstall");
const LINK_BIN = args.has("--link-bin");

function log(...parts) { console.log(`[safedeps-install]`, ...parts); }
function warn(...parts) { console.warn(`[safedeps-install]`, ...parts); }

function isSymlink(p) {
  try { return lstatSync(p).isSymbolicLink(); } catch { return false; }
}

function ensureSymlink(target, linkPath) {
  if (isSymlink(linkPath)) {
    const current = readlinkSync(linkPath);
    if (current === target) { log(`symlink ok   ${linkPath} -> ${target}`); return; }
    unlinkSync(linkPath);
  } else if (existsSync(linkPath)) {
    throw new Error(`refusing to overwrite non-symlink at ${linkPath}`);
  }
  mkdirSync(dirname(linkPath), { recursive: true });
  symlinkSync(target, linkPath);
  log(`symlink wrote ${linkPath} -> ${target}`);
}

function removeSymlink(linkPath) {
  if (isSymlink(linkPath)) {
    unlinkSync(linkPath);
    log(`symlink removed ${linkPath}`);
  }
}

function readJson(path) {
  if (!existsSync(path)) return {};
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    throw new Error(`invalid JSON at ${path}: ${err.message}`);
  }
}

function writeJsonWithBackup(path, value) {
  if (existsSync(path)) {
    copyFileSync(path, `${path}.bak`);
  } else {
    mkdirSync(dirname(path), { recursive: true });
  }
  writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
}

function ensureHook(config, eventName, command) {
  config.hooks = config.hooks ?? {};
  config.hooks[eventName] = config.hooks[eventName] ?? [];
  const buckets = config.hooks[eventName];

  let bashBucket = buckets.find((b) => b && b.matcher === "Bash");
  if (!bashBucket) {
    bashBucket = { matcher: "Bash", hooks: [] };
    buckets.push(bashBucket);
  }
  bashBucket.hooks = bashBucket.hooks ?? [];

  const already = bashBucket.hooks.some((h) => h && h.type === "command" && h.command === command);
  if (already) return false;

  bashBucket.hooks.push({ type: "command", command });
  return true;
}

function removeHook(config, eventName, command) {
  const buckets = config?.hooks?.[eventName];
  if (!Array.isArray(buckets)) return false;
  let changed = false;
  for (const bucket of buckets) {
    if (!bucket || bucket.matcher !== "Bash" || !Array.isArray(bucket.hooks)) continue;
    const before = bucket.hooks.length;
    bucket.hooks = bucket.hooks.filter((h) => !(h && h.type === "command" && h.command === command));
    if (bucket.hooks.length !== before) changed = true;
  }
  return changed;
}

function installInEngine({ engineRoot, configPath, label }) {
  if (!existsSync(engineRoot)) {
    warn(`skip ${label} (${engineRoot} not present)`);
    return;
  }
  const skillsRoot = join(engineRoot, "skills");
  const skillLink = join(skillsRoot, SKILL_ID);

  if (UNINSTALL) {
    removeSymlink(skillLink);
    if (existsSync(configPath)) {
      const cfg = readJson(configPath);
      const pre = removeHook(cfg, "PreToolUse", PRE_HOOK);
      const post = removeHook(cfg, "PostToolUse", POST_HOOK);
      if (pre || post) {
        writeJsonWithBackup(configPath, cfg);
        log(`patched ${configPath} (removed safedeps hooks)`);
      } else {
        log(`config clean ${configPath}`);
      }
    }
    return;
  }

  ensureSymlink(REPO_ROOT, skillLink);

  const cfg = readJson(configPath);
  const preAdded = ensureHook(cfg, "PreToolUse", PRE_HOOK);
  const postAdded = ensureHook(cfg, "PostToolUse", POST_HOOK);
  if (preAdded || postAdded) {
    writeJsonWithBackup(configPath, cfg);
    log(`patched ${configPath} (pre=${preAdded ? "added" : "ok"}, post=${postAdded ? "added" : "ok"})`);
  } else {
    log(`config ok   ${configPath} (hooks already registered)`);
  }
}

function maybeLinkBin() {
  if (!LINK_BIN || UNINSTALL) return;
  const target = CLI_BIN;
  const linkPath = join(HOME, ".local", "bin", "safedeps");
  try {
    ensureSymlink(target, linkPath);
  } catch (err) {
    warn(`bin symlink skipped: ${err.message}`);
  }
}

function unlinkBin() {
  if (!UNINSTALL) return;
  removeSymlink(join(HOME, ".local", "bin", "safedeps"));
}

function main() {
  if (!existsSync(PRE_HOOK) || !existsSync(POST_HOOK)) {
    throw new Error(`hook scripts not found at ${PRE_HOOK} / ${POST_HOOK}`);
  }

  installInEngine({
    engineRoot: join(HOME, ".claude"),
    configPath: join(HOME, ".claude", "settings.json"),
    label: "Claude Code",
  });
  installInEngine({
    engineRoot: join(HOME, ".codex"),
    configPath: join(HOME, ".codex", "hooks.json"),
    label: "Codex CLI",
  });

  maybeLinkBin();
  unlinkBin();

  if (UNINSTALL) {
    log("uninstall done.");
  } else {
    log("install done. New hook events fire on the next session start.");
  }
}

main();
