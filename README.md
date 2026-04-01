# npm-reorg-guard

> Blockchain reorg meets npm security -- snapshot, verify, and auto-rollback suspicious package installs in Claude Code.

## Why "reorg"?

In blockchain networks, a **reorganization (reorg)** invalidates a sequence of blocks and reverts the chain to a previously confirmed safe state. `npm-reorg-guard` applies the same principle to your `node_modules`: every `npm install` is treated as an unconfirmed block candidate until it passes a battery of supply-chain security checks. If anything looks wrong, the tool performs a **reorg** -- rolling back lock files, `package.json`, and `node_modules` to the last confirmed safe snapshot.

No manual review. No leftover malicious code. Fully automatic.

## How It Works

`npm-reorg-guard` plugs into [Claude Code's hook system](https://docs.anthropic.com/en/docs/claude-code/hooks) as a pair of **PreToolUse** and **PostToolUse** hooks that wrap every package install command.

```
                         PreToolUse                          PostToolUse
                        (guard.sh)                          (verify.sh)
                            |                                    |
  npm install ──> [ Pre-flight checks ] ──> [ Execute ] ──> [ Verify ]
                     |            |                           |       |
                  Block if      Snapshot                   Clean?  Suspicious?
                  suspicious    lock files,                  |       |
                               package.json,              Confirm  REORG
                               node_modules list            |       |
                                    |                       v       v
                                    +--- parent_snapshot_id ──> confirmed
                                                                    |
                                                              Rollback to last
                                                              confirmed snapshot
```

### Phase 1: Pre-flight (guard.sh -- PreToolUse)

When Claude Code is about to run `npm install`, `pnpm add`, `yarn add`, or similar commands, the guard hook:

1. **Snapshots** the current `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, and `package.json` into `~/.npm-reorg-guard/snapshots/`.
2. **Records metadata** including a `parent_snapshot_id` linking to the previous confirmed snapshot (forming a chain, just like blocks).
3. **Captures pre-install state** of `node_modules` (package listings and binary listings) for diff-based detection later.
4. **Runs pre-flight checks** and **blocks** the command entirely if it detects:
   - Typosquatting package names (`lod_sh`, `reacct`, `axois`, etc.)
   - Non-standard `--registry` URLs (anything outside `registry.npmjs.org` and `registry.yarnpkg.com`)
   - Piped remote execution patterns (`curl ... | bash`)
   - Explicit disabling of install script safety (`npm config set ignore-scripts false`)

If a pre-flight check fails, the command is **blocked before execution** -- nothing is installed.

### Phase 2: Post-install verification (verify.sh -- PostToolUse)

After the install command completes, the verify hook analyzes what changed:

1. **Install script analysis** -- Scans newly added packages for `preinstall`, `install`, and `postinstall` scripts containing:
   - Network access (`curl`, `wget`, `fetch`, `http`, `socket`, `dns`)
   - Dynamic code execution (`eval`, `exec`, `spawn`, `child_process`, `Function()`)
   - Sensitive path access (`~/.ssh`, `.env`, `.aws`, `credentials`)
   - Obfuscated content (`base64`, `atob`, `Buffer.from`, hex/unicode escapes)

2. **Lock file diff analysis** -- Compares the snapshotted lock file content against the post-install version:
   - Resolved URLs pointing to non-standard registries
   - Insecure protocols (`http://`, `git://`) in resolved URLs
   - Unusually large dependency additions (>50 new resolved entries, indicating potential dependency confusion)

3. **Binary inspection** -- Checks `node_modules/.bin/` for newly added native binaries (ELF, Mach-O, shared objects) that should not appear in a JavaScript project.

### Phase 3: Confirm or Reorg

- **All checks pass** -- The snapshot is marked as **confirmed** in `~/.npm-reorg-guard/confirmed`. This becomes the new safe baseline.
- **Any check fails** -- A **reorg** is triggered:
  1. Lock files are restored from the last confirmed snapshot.
  2. `package.json` is restored if it was modified.
  3. `node_modules` is rebuilt via `npm ci` (or `npm install` as fallback) to purge any malicious artifacts.
  4. The event is logged to `~/.npm-reorg-guard/reorg.log`.
  5. Claude Code receives a system message detailing the detected threats and rollback actions.

## The Blockchain Analogy

| Blockchain Concept | npm-reorg-guard Equivalent |
|---|---|
| **Block candidate** | Snapshot taken before `npm install` |
| **Block validation** | Post-install security checks (scripts, lock diff, binaries) |
| **Finality / confirmation** | Snapshot ID written to `~/.npm-reorg-guard/confirmed` |
| **Chain reorganization** | Rollback to last confirmed snapshot + `node_modules` rebuild |
| **Parent hash linking** | `parent_snapshot_id` in each snapshot's `_meta.json` |
| **Chain pruning** | Old unconfirmed snapshots cleaned up, confirmed chain preserved |

## Detection Rules

| Category | What it catches | Phase | Action |
|---|---|---|---|
| Typosquatting | Known misspelling patterns of popular packages | Pre-flight | **Block** |
| Pipe execution | `curl \| bash`, `wget \| sh` | Pre-flight | **Block** |
| Registry hijack | `--registry` pointing to unofficial sources | Pre-flight | **Block** |
| Script safety bypass | `npm config set ignore-scripts false` | Pre-flight | **Block** |
| Malicious install scripts | Network calls, `eval`/`exec`, sensitive path access in hooks | Post-install | **Reorg** |
| Obfuscated code | Base64, hex encoding, `Buffer.from` in install scripts | Post-install | **Reorg** |
| Lock file tampering | Resolved URLs from non-standard registries | Post-install | **Reorg** |
| Insecure protocols | `http://` or `git://` resolved URLs | Post-install | **Reorg** |
| Dependency confusion | >50 new dependencies in a single install | Post-install | **Reorg** |
| Native binaries | Compiled executables in `node_modules/.bin/` | Post-install | **Reorg** |

## Installation

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with hook support
- `jq` -- JSON parsing (hooks exit gracefully if missing)
- `shasum` or `sha256sum` -- hash computation
- `file` (optional) -- binary detection

```bash
# macOS
brew install jq

# Ubuntu / Debian
sudo apt-get install jq
```

### Setup

**1. Clone the repository:**

```bash
git clone https://github.com/soohongkim/npm-reorg-guard.git
cp -r npm-reorg-guard ~/.claude/skills/
```

**2. Add hooks to your Claude Code settings:**

Edit `.claude/settings.json` (project-level) or `~/.claude/settings.json` (global):

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

**3. Verify permissions:**

```bash
chmod +x ~/.claude/skills/npm-reorg-guard/scripts/guard.sh
chmod +x ~/.claude/skills/npm-reorg-guard/scripts/verify.sh
```

That's it. The guard activates automatically whenever Claude Code runs a package install command.

## Real-World Attack Coverage

`npm-reorg-guard` is designed to catch the patterns behind real supply-chain incidents:

- **`event-stream` (2018)** -- Malicious `postinstall` script with obfuscated code that exfiltrated cryptocurrency wallet keys. Caught by: install script analysis (obfuscation + network access detection).
- **`ua-parser-js` hijack (2021)** -- Compromised package added a `preinstall` script that downloaded and executed cryptominers. Caught by: install script analysis (network access + code execution).
- **`colors` / `faker` sabotage (2022)** -- While these were author-initiated, the abnormal dependency behavior would trigger the dependency explosion check.
- **Typosquatting campaigns** -- Ongoing campaigns publishing packages like `crossenv` (instead of `cross-env`) or `babelcli` (instead of `babel-cli`). Caught by: pre-flight typosquatting pattern matching.
- **Dependency confusion attacks** -- Internal package names published to the public registry with higher version numbers. Caught by: non-standard registry detection + large dependency count changes.

## Logs and Snapshots

| Path | Description |
|---|---|
| `~/.npm-reorg-guard/reorg.log` | Full reorg event history with timestamps, reasons, and rolled-back files |
| `~/.npm-reorg-guard/confirmed` | Current confirmed (safe) snapshot ID |
| `~/.npm-reorg-guard/snapshots/` | All snapshot files (lock files, package.json copies, metadata) |

```bash
# View reorg history
cat ~/.npm-reorg-guard/reorg.log

# Check current confirmed snapshot
cat ~/.npm-reorg-guard/confirmed

# List all snapshots
ls -la ~/.npm-reorg-guard/snapshots/
```

Old unconfirmed snapshots are automatically pruned (keeping the 10 most recent), while the confirmed snapshot chain is always preserved.

## Project Structure

```
npm-reorg-guard/
  scripts/
    guard.sh      # PreToolUse hook -- snapshot + pre-flight checks
    verify.sh     # PostToolUse hook -- post-install verification + reorg
  package.json
  skill.md        # Claude Code skill manifest
  LICENSE         # Apache-2.0
```

## License

[Apache License 2.0](LICENSE)
