#!/usr/bin/env bash
# npm-reorg-guard: PreToolUse hook
# Blockchain reorg concept applied to npm security
# Detects package install commands and snapshots lock files before execution

set -euo pipefail

GUARD_DIR="${HOME}/.npm-reorg-guard"
SNAPSHOT_DIR="${GUARD_DIR}/snapshots"
STATE_LOCK_DIR="${GUARD_DIR}/state.lock"

mkdir -p "${GUARD_DIR}" "${SNAPSHOT_DIR}"

if ! command -v jq >/dev/null 2>&1; then
  echo "npm-reorg-guard: jq is not installed; skipping guard hook." >&2
  exit 0
fi

acquire_state_lock() {
  local attempts=0

  while ! mkdir "${STATE_LOCK_DIR}" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ ${attempts} -ge 100 ]]; then
      echo "npm-reorg-guard: could not acquire state lock; skipping guard hook." >&2
      exit 0
    fi
    sleep 0.1
  done
}

release_state_lock() {
  rmdir "${STATE_LOCK_DIR}" 2>/dev/null || true
}

write_state_file() {
  local target_path="$1"
  local value="$2"
  local temp_path="${target_path}.$$"

  printf '%s\n' "${value}" > "${temp_path}"
  mv "${temp_path}" "${target_path}"
}

compute_dir_hash() {
  local input_dir="$1"

  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "${input_dir}" | md5sum | cut -d' ' -f1
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q -s "${input_dir}"
  else
    echo "unknown"
  fi
}

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
INSTALL_PATTERN='(npm[[:space:]]+(install|i|add|update|up|upgrade)|pnpm[[:space:]]+(add|install|update|up)|yarn[[:space:]]+(add|install|upgrade))'

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
DIR_HASH=$(compute_dir_hash "${PROJECT_DIR}")
SNAPSHOT_ID="${TIMESTAMP}_${DIR_HASH}"

acquire_state_lock
trap 'release_state_lock' EXIT

PARENT_SNAPSHOT_ID=""
if [[ -f "${GUARD_DIR}/confirmed" ]]; then
  PARENT_SNAPSHOT_ID=$(cat "${GUARD_DIR}/confirmed" 2>/dev/null || true)
fi

if [[ -n "${PARENT_SNAPSHOT_ID}" ]] && [[ ! -f "${SNAPSHOT_DIR}/${PARENT_SNAPSHOT_ID}_meta.json" ]]; then
  PARENT_SNAPSHOT_ID=""
fi

PARENT_SNAPSHOT_JSON=$(printf '%s' "${PARENT_SNAPSHOT_ID}" | jq -Rs 'if length == 0 then null else . end')

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

# Save pre-install listings for diff-based detection (avoids mtime-based find -newer)
if [[ -d "${PROJECT_DIR}/node_modules" ]]; then
  find "${PROJECT_DIR}/node_modules" -maxdepth 3 -name "package.json" 2>/dev/null | sort > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_packages.list"
  ls "${PROJECT_DIR}/node_modules/.bin/" 2>/dev/null | sort > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_bins.list"
else
  touch "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_packages.list"
  touch "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_bins.list"
fi

# Store metadata for PostToolUse verification
cat > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_meta.json" << META_EOF
{
  "snapshot_id": "${SNAPSHOT_ID}",
  "parent_snapshot_id": ${PARENT_SNAPSHOT_JSON},
  "timestamp": ${TIMESTAMP},
  "project_dir": "${PROJECT_DIR}",
  "command": $(echo "${COMMAND}" | jq -Rs .),
  "lock_files_found": ${SNAPSHOTTED}
}
META_EOF

# --- Pre-flight security checks on the command itself ---

SUSPICIOUS=false
REASONS=()

# Check for piped install from suspicious sources
if echo "${COMMAND}" | grep -qEi 'curl.*\|[[:space:]]*(bash|sh|node)'; then
  SUSPICIOUS=true
  REASONS+=("Command pipes remote content to shell execution")
fi

# Check for install with --ignore-scripts being removed (attacker might want scripts to run)
if echo "${COMMAND}" | grep -qEi 'npm[[:space:]]+config[[:space:]]+set[[:space:]]+ignore-scripts[[:space:]]+false'; then
  SUSPICIOUS=true
  REASONS+=("Command explicitly enables install scripts")
fi

# Check for registry override to unknown registry
if echo "${COMMAND}" | grep -qEi -- '--registry([=[:space:]]+)'; then
  if ! echo "${COMMAND}" | grep -qEi -- '--registry([=[:space:]]+)https?://(registry\.npmjs\.org|registry\.yarnpkg\.com)(/|[[:space:]]|$)'; then
    SUSPICIOUS=true
    REASONS+=("Command uses non-standard npm registry")
  fi
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

# Write current snapshot ID for PostToolUse to pick up only when the command is allowed
write_state_file "${GUARD_DIR}/current_snapshot_id" "${SNAPSHOT_ID}"
write_state_file "${GUARD_DIR}/current_project_dir" "${PROJECT_DIR}"

# Allow the command to proceed — PostToolUse will verify the result
exit 0
