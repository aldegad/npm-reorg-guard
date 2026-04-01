#!/usr/bin/env bash
# npm-reorg-guard: PreToolUse hook
# Blockchain reorg concept applied to npm security
# Detects package install commands and snapshots lock files before execution

set -euo pipefail

GUARD_DIR="${HOME}/.npm-reorg-guard"
SNAPSHOT_DIR="${GUARD_DIR}/snapshots"
mkdir -p "${SNAPSHOT_DIR}"

# Read tool input from stdin
INPUT=$(cat)

# Extract tool name and command
TOOL_NAME=$(echo "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
COMMAND=$(echo "${INPUT}" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Only intercept Bash tool calls
if [[ "${TOOL_NAME}" != "Bash" ]] || [[ -z "${COMMAND}" ]]; then
  exit 0
fi

# Detect package install/update commands
INSTALL_PATTERN='(npm\s+(install|i|add|update|up|upgrade)|pnpm\s+(add|install|update|up)|yarn\s+(add|install|upgrade))'

if ! echo "${COMMAND}" | grep -qEi "${INSTALL_PATTERN}"; then
  exit 0
fi

# --- Reorg Guard Activated ---

# Find lock files in common locations
PROJECT_DIR=$(echo "${INPUT}" | jq -r '.tool_input.cwd // empty' 2>/dev/null)
if [[ -z "${PROJECT_DIR}" ]]; then
  PROJECT_DIR=$(pwd)
fi

TIMESTAMP=$(date +%s)
SNAPSHOT_ID="${TIMESTAMP}_$(echo "${PROJECT_DIR}" | md5sum 2>/dev/null | cut -d' ' -f1 || md5 -q -s "${PROJECT_DIR}" 2>/dev/null || echo "unknown")"

# Snapshot all lock files found
LOCK_FILES=("package-lock.json" "pnpm-lock.yaml" "yarn.lock")
SNAPSHOTTED=false

for lock_file in "${LOCK_FILES[@]}"; do
  LOCK_PATH="${PROJECT_DIR}/${lock_file}"
  if [[ -f "${LOCK_PATH}" ]]; then
    cp "${LOCK_PATH}" "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${lock_file}"
    # Store hash for quick comparison
    if command -v shasum &>/dev/null; then
      shasum -a 256 "${LOCK_PATH}" > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${lock_file}.sha256"
    elif command -v sha256sum &>/dev/null; then
      sha256sum "${LOCK_PATH}" > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${lock_file}.sha256"
    fi
    SNAPSHOTTED=true
  fi
done

# Also snapshot package.json to detect postinstall script injection
if [[ -f "${PROJECT_DIR}/package.json" ]]; then
  cp "${PROJECT_DIR}/package.json" "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_package.json"
fi

# Store metadata for PostToolUse verification
cat > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_meta.json" << META_EOF
{
  "snapshot_id": "${SNAPSHOT_ID}",
  "timestamp": ${TIMESTAMP},
  "project_dir": "${PROJECT_DIR}",
  "command": $(echo "${COMMAND}" | jq -Rs .),
  "lock_files_found": ${SNAPSHOTTED}
}
META_EOF

# Write current snapshot ID for PostToolUse to pick up
echo "${SNAPSHOT_ID}" > "${GUARD_DIR}/current_snapshot_id"
echo "${PROJECT_DIR}" > "${GUARD_DIR}/current_project_dir"

# --- Pre-flight security checks on the command itself ---

SUSPICIOUS=false
REASONS=()

# Check for piped install from suspicious sources
if echo "${COMMAND}" | grep -qEi 'curl.*\|\s*(bash|sh|node)'; then
  SUSPICIOUS=true
  REASONS+=("Command pipes remote content to shell execution")
fi

# Check for install with --ignore-scripts being removed (attacker might want scripts to run)
if echo "${COMMAND}" | grep -qEi 'npm\s+config\s+set\s+ignore-scripts\s+false'; then
  SUSPICIOUS=true
  REASONS+=("Command explicitly enables install scripts")
fi

# Check for registry override to unknown registry
if echo "${COMMAND}" | grep -qEi '--registry\s+https?://(?!registry\.npmjs\.org|registry\.yarnpkg\.com)'; then
  SUSPICIOUS=true
  REASONS+=("Command uses non-standard npm registry")
fi

# Check for packages with suspicious naming patterns (typosquatting indicators)
TYPOSQUAT_PATTERNS='(lod[a-z]sh|reacct|exprss|axois|babeel|webpackk|esliint|l0dash|m0ment|4xios)'
if echo "${COMMAND}" | grep -qEi "${TYPOSQUAT_PATTERNS}"; then
  SUSPICIOUS=true
  REASONS+=("Package name matches known typosquatting patterns")
fi

if [[ "${SUSPICIOUS}" == "true" ]]; then
  REASON_STR=$(printf '%s; ' "${REASONS[@]}")
  cat << EOF
{"decision": "block", "reason": "npm-reorg-guard: ${REASON_STR%%; }"}
EOF
  exit 0
fi

# Allow the command to proceed — PostToolUse will verify the result
exit 0
