#!/bin/bash
set -euo pipefail

# safedeps hooks install|check — generic repo-local git hook activation.
# Absorbed from kuma-studio scripts/security/{install,check}-hooks.sh.
# The repo's privacy/secret policy lives in its own .githooks/pre-commit;
# this command only manages hook activation, not the policy content.

GATES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./repo-profile.sh
source "$GATES_LIB_DIR/repo-profile.sh"

SUB=""
REPO_ROOT=""
HOOKS_PATH=".githooks"
AUTO=0

usage() {
  printf 'Usage: safedeps hooks <install|check> [--root <repo>] [--hooks-path <dir>] [--auto]\n' >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    install|check) SUB="$1"; shift ;;
    --root) REPO_ROOT="${2:?--root needs a path}"; shift 2 ;;
    --hooks-path) HOOKS_PATH="${2:?--hooks-path needs a dir}"; shift 2 ;;
    --auto) AUTO=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

if [ -z "$SUB" ]; then usage; exit 64; fi
if [ -z "$REPO_ROOT" ]; then REPO_ROOT="$(pwd)"; fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ "$SUB" = "install" ] && [ "$AUTO" -eq 1 ]; then
    printf 'safedeps hooks: skipped install (not a git worktree)\n'
    exit 0
  fi
  printf 'ERROR: not inside a git worktree: %s\n' "$REPO_ROOT" >&2
  exit 1
fi

HOOK_FILE="$REPO_ROOT/$HOOKS_PATH/pre-commit"

case "$SUB" in
  install)
    if [ ! -f "$HOOK_FILE" ]; then
      printf 'ERROR: hook file not found: %s\n' "$HOOK_FILE" >&2
      printf '       the repo must provide its own %s/pre-commit policy.\n' "$HOOKS_PATH" >&2
      exit 1
    fi
    chmod +x "$HOOK_FILE"
    git -C "$REPO_ROOT" config core.hooksPath "$HOOKS_PATH"
    printf 'safedeps hooks: installed repo-local git hooks at %s/%s\n' "$REPO_ROOT" "$HOOKS_PATH"
    printf 'safedeps hooks: core.hooksPath = %s\n' "$(git -C "$REPO_ROOT" config --get core.hooksPath)"
    ;;
  check)
    local_expected="$HOOKS_PATH"
    actual="$(git -C "$REPO_ROOT" config --get core.hooksPath || true)"
    if [ "$actual" != "$local_expected" ]; then
      cat >&2 <<EOF
ERROR: repo-local git hooks are not active.

Expected core.hooksPath: $local_expected
Actual core.hooksPath:   ${actual:-<unset>}

Run:
  safedeps hooks install --root "$REPO_ROOT"
EOF
      exit 1
    fi
    if [ ! -x "$HOOK_FILE" ]; then
      printf 'ERROR: %s is not executable.\n' "$HOOK_FILE" >&2
      exit 1
    fi
    if ! command -v gitleaks >/dev/null 2>&1; then
      if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        cat >&2 <<'EOF'
ERROR: neither local gitleaks nor a running Docker daemon is available.

Choose one:
  brew install gitleaks
  open -a Docker
EOF
        exit 1
      fi
    fi
    printf 'safedeps hooks: active (core.hooksPath = %s)\n' "$local_expected"
    ;;
esac
