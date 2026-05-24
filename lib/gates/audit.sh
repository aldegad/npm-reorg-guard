#!/bin/bash
set -euo pipefail

# safedeps audit npm — generic npm lockfile audit.
# Absorbed from kuma-studio scripts/security/run-npm-audit.sh.
# Missing lockfile stays fail-closed (no reproducible verdict without it).

REPO_ROOT=""
AUDIT_LEVEL="${SAFEDEPS_NPM_AUDIT_LEVEL:-${KUMA_NPM_AUDIT_LEVEL:-moderate}}"

usage() {
  printf 'Usage: safedeps audit [npm] [--root <repo>] [--level <low|moderate|high|critical>]\n' >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    npm) shift ;; # allow `audit npm`
    --root) REPO_ROOT="${2:?--root needs a path}"; shift 2 ;;
    --level) AUDIT_LEVEL="${2:?--level needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then REPO_ROOT="$(pwd)"; fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
cd "$REPO_ROOT"

if [ ! -f package-lock.json ]; then
  cat >&2 <<'EOF'
ERROR: package-lock.json is missing, so npm audit cannot produce a reproducible dependency verdict.
EOF
  exit 1
fi

exec npm audit --audit-level="$AUDIT_LEVEL"
