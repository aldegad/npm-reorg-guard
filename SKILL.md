---
name: npm-reorg-guard
description: Blockchain reorg concept applied to npm package security — snapshots lock files before installs, confirms safe snapshots, and auto-rolls back suspicious changes
hooks:
  - type: PreToolUse
    script: scripts/guard.sh
  - type: PostToolUse
    script: scripts/verify.sh
---

# npm-reorg-guard

Blockchain reorg concept applied to npm supply-chain security for Claude Code.

## How It Works

1. Detects package install commands (`npm install`, `pnpm add`, `yarn add`, `npx`, etc.) and snapshots lock files into `~/.npm-reorg-guard/snapshots/` with a `parent_snapshot_id` forming a chain.
2. After install completes, analyzes lock file diffs, install scripts, and `node_modules/.bin/` for suspicious patterns.
3. If all checks pass, the snapshot is **confirmed** as the new safe baseline (project-scoped via `confirmed_${dir_hash}`).
4. If anything is suspicious, a **reorg** rolls back to the last confirmed snapshot and reinstalls `node_modules`.

## Threat Detection

**Pre-flight (blocks before execution):**
- Non-standard `--registry` URLs
- Typosquatting package names (`lod_sh`, `reacct`, `axois`, etc.)
- Piped remote execution (`curl | bash`)
- Disabling install script safety
- Command indirection (`eval`, subshell expansion) hiding install commands
- `npx`, `pnpm dlx`, `yarn dlx` execution

**Post-install (triggers reorg):**
- Install scripts with network access, code execution, or sensitive path access
- Obfuscated content (base64, hex encoding)
- Lock file resolved URLs from non-standard registries or insecure protocols
- Unusually large dependency additions (>50 new entries)
- Native binaries in `node_modules/.bin/`

## Security Hardening

- JSON-safe metadata (PROJECT_DIR escaped via `jq -Rs`)
- Path canonicalization (`realpath`/`readlink -f`) prevents traversal attacks
- Atomic state files prevent TOCTOU race conditions
- Stale lock recovery (auto-remove locks >60s old)
- Project-scoped confirmed state prevents cross-project interference
- Restrictive permissions (`umask 077`)

## Installation

### 1. Copy to skills directory

```bash
cp -r npm-reorg-guard ~/.claude/skills/
```

### 2. Add hooks to Claude Code settings

In `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/skills/npm-reorg-guard/scripts/guard.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/skills/npm-reorg-guard/scripts/verify.sh"
          }
        ]
      }
    ]
  }
}
```

### 3. Dependencies

- `jq` -- JSON parsing (hooks skip gracefully if missing)
- `shasum` or `sha256sum` -- hash computation
- `file` (optional) -- binary detection

```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt-get install jq
```

## Logs

Reorg events are logged to `~/.npm-reorg-guard/reorg.log`.

```bash
cat ~/.npm-reorg-guard/reorg.log
```

Confirmed snapshot IDs are stored per-project in `~/.npm-reorg-guard/confirmed_${dir_hash}`.

Snapshots are stored in `~/.npm-reorg-guard/snapshots/`. Old unconfirmed snapshots are pruned (keeping the 10 most recent), while the confirmed chain is always preserved.
