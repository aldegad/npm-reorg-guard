#!/usr/bin/env bash
# safedeps: PreToolUse hook
# Dependency install safety gate with reorg rollback support
# Detects package install commands and snapshots lock files before execution

set -euo pipefail

GUARD_DIR="${SAFEDEPS_HOME:-${HOME}/.safedeps}"
SNAPSHOT_DIR="${GUARD_DIR}/snapshots"
STATE_LOCK_DIR="${GUARD_DIR}/state.lock"

SAFEDEPS_LOCK_FILES=(
  "package-lock.json"
  "pnpm-lock.yaml"
  "yarn.lock"
  "poetry.lock"
  "uv.lock"
  "Pipfile.lock"
  "requirements.txt"
  "Cargo.lock"
  "go.sum"
  "Gemfile.lock"
  "packages.lock.json"
)

SAFEDEPS_MANIFEST_FILES=(
  "package.json"
  "pyproject.toml"
  "Pipfile"
  "Cargo.toml"
  "go.mod"
  "Gemfile"
  "pom.xml"
)

umask 077
mkdir -p "${GUARD_DIR}" "${SNAPSHOT_DIR}"

if ! command -v jq >/dev/null 2>&1; then
  echo "safedeps: jq is not installed; skipping guard hook." >&2
  exit 0
fi

acquire_state_lock() {
  local attempts=0

  while ! mkdir "${STATE_LOCK_DIR}" 2>/dev/null; do
    # Detect stale locks left by SIGKILL/OOM (V-005)
    if [[ -d "${STATE_LOCK_DIR}" ]]; then
      local lock_mtime=""
      if lock_mtime=$(stat -f %m "${STATE_LOCK_DIR}" 2>/dev/null) || \
         lock_mtime=$(stat -c %Y "${STATE_LOCK_DIR}" 2>/dev/null); then
        local now
        now=$(date +%s)
        if [[ $(( now - lock_mtime )) -gt 60 ]]; then
          echo "safedeps: removing stale lock ($(( now - lock_mtime ))s old)." >&2
          rmdir "${STATE_LOCK_DIR}" 2>/dev/null || true
          continue
        fi
      fi
    fi

    attempts=$((attempts + 1))
    if [[ ${attempts} -ge 100 ]]; then
      echo "safedeps: could not acquire state lock; skipping guard hook." >&2
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
    printf '%s' "${input_dir}" | cksum | cut -d' ' -f1
  fi
}

command_is_dependency_install() {
  local command="$1"
  local scan_command
  local install_pattern

  scan_command=$(command_scan_text "${command}")
  install_pattern='(^|[;&|]+[[:space:]]*)((npm[[:space:]]+(install|i|add|update|up|upgrade))|npx[[:space:]]|pnpm[[:space:]]+(add|install|update|up|dlx)|yarn[[:space:]]+(add|install|upgrade|dlx)|((python3?|py)[[:space:]]+-m[[:space:]]+pip|pip3?)[[:space:]]+install|poetry[[:space:]]+add|uv[[:space:]]+(add|pip[[:space:]]+install)|pipenv[[:space:]]+install|cargo[[:space:]]+(add|install)|go[[:space:]]+(get|install)|gem[[:space:]]+install|bundle[[:space:]]+add|mvn[[:space:]]+dependency:get|dotnet[[:space:]]+add[[:space:]]+package)([[:space:]]|$)'

  echo "${scan_command}" | grep -qEi "${install_pattern}"
}

command_hides_dependency_install() {
  local command="$1"
  local manager_pattern
  local verb_pattern

  manager_pattern='(npm|npx|pnpm|yarn|pip3?|python3?[[:space:]]+-m[[:space:]]+pip|poetry|uv|pipenv|cargo|go|gem|bundle|mvn|dotnet)'
  verb_pattern='(install|i|add|update|up|upgrade|dlx|get|dependency:get|package)'

  echo "${command}" | grep -qEi '(eval[[:space:]]|\$\(|`)' && \
    echo "${command}" | grep -qEi "${manager_pattern}.*${verb_pattern}"
}

command_scan_text() {
  local input="$1"
  local output=""
  local quote=""
  local char
  local prev=""
  local i

  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"

    if [[ -z "${quote}" ]]; then
      if [[ "${char}" == "'" ]]; then
        quote="single"
        output="${output} "
      elif [[ "${char}" == '"' ]]; then
        quote="double"
        output="${output} "
      else
        output="${output}${char}"
      fi
    elif [[ "${quote}" == "single" && "${char}" == "'" ]]; then
      quote=""
      output="${output} "
    elif [[ "${quote}" == "double" && "${char}" == '"' && "${prev}" != "\\" ]]; then
      quote=""
      output="${output} "
    else
      output="${output} "
    fi

    prev="${char}"
  done

  printf '%s' "${output}"
}

snapshot_project_file() {
  local relative_file="$1"
  local category="${2:-manifest}"
  local source_path="${PROJECT_DIR}/${relative_file}"
  local snapshot_path="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${relative_file}"

  printf '%s\n' "${relative_file}" >> "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_monitored_files.list"

  if [[ -f "${source_path}" ]]; then
    cp "${source_path}" "${snapshot_path}"
    if command -v shasum &>/dev/null; then
      shasum -a 256 "${source_path}" > "${snapshot_path}.sha256"
    elif command -v sha256sum &>/dev/null; then
      sha256sum "${source_path}" > "${snapshot_path}.sha256"
    fi
    if [[ "${category}" == "lock" ]]; then
      SNAPSHOTTED=true
    fi
  else
    touch "${snapshot_path}.missing"
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

if ! command_is_dependency_install "${COMMAND}"; then
  # Catch indirection patterns that hide install commands (V-002)
  if command_hides_dependency_install "${COMMAND}"; then
    : # Fall through — treat as install candidate
  else
    exit 0
  fi
fi

# --- Reorg Guard Activated ---

# Find lock files in common locations
# Per Claude Code / Codex CLI hook spec, `cwd` is top-level. Fall back to `pwd`
# only when the hook is invoked outside the engine (manual test, no stdin payload).
PROJECT_DIR=$(echo "${INPUT}" | jq -r '.cwd // empty' 2>/dev/null)
if [[ -z "${PROJECT_DIR}" ]]; then
  PROJECT_DIR=$(pwd)
fi

# Canonicalize to prevent path traversal (V-003)
if command -v realpath >/dev/null 2>&1; then
  PROJECT_DIR=$(realpath "${PROJECT_DIR}" 2>/dev/null || echo "${PROJECT_DIR}")
elif command -v readlink >/dev/null 2>&1; then
  PROJECT_DIR=$(readlink -f "${PROJECT_DIR}" 2>/dev/null || echo "${PROJECT_DIR}")
fi

TIMESTAMP=$(date +%s)
DIR_HASH=$(compute_dir_hash "${PROJECT_DIR}")
SNAPSHOT_ID="${TIMESTAMP}_${DIR_HASH}"

acquire_state_lock
trap 'release_state_lock' EXIT

PARENT_SNAPSHOT_ID=""
CONFIRMED_FILE="${GUARD_DIR}/confirmed_${DIR_HASH}"
if [[ -f "${CONFIRMED_FILE}" ]]; then
  PARENT_SNAPSHOT_ID=$(cat "${CONFIRMED_FILE}" 2>/dev/null || true)
fi

if [[ -n "${PARENT_SNAPSHOT_ID}" ]] && [[ ! -f "${SNAPSHOT_DIR}/${PARENT_SNAPSHOT_ID}_meta.json" ]]; then
  # Fallback: check legacy global confirmed file for migration
  if [[ -f "${GUARD_DIR}/confirmed" ]]; then
    PARENT_SNAPSHOT_ID=$(cat "${GUARD_DIR}/confirmed" 2>/dev/null || true)
    if [[ -n "${PARENT_SNAPSHOT_ID}" ]] && [[ ! -f "${SNAPSHOT_DIR}/${PARENT_SNAPSHOT_ID}_meta.json" ]]; then
      PARENT_SNAPSHOT_ID=""
    fi
  else
    PARENT_SNAPSHOT_ID=""
  fi
fi

PARENT_SNAPSHOT_JSON=$(printf '%s' "${PARENT_SNAPSHOT_ID}" | jq -Rs 'if length == 0 then null else . end')

# Snapshot lock and manifest files that define dependency truth.
SNAPSHOTTED=false
: > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_monitored_files.list"

for lock_file in "${SAFEDEPS_LOCK_FILES[@]}"; do
  snapshot_project_file "${lock_file}" "lock"
done

for manifest_file in "${SAFEDEPS_MANIFEST_FILES[@]}"; do
  snapshot_project_file "${manifest_file}" "manifest"
done

while IFS= read -r csproj_file; do
  snapshot_project_file "$(basename "${csproj_file}")" "manifest"
done < <(find "${PROJECT_DIR}" -maxdepth 1 -type f -name "*.csproj" 2>/dev/null | sort)

# Save pre-install listings for diff-based detection (avoids mtime-based find -newer)
if [[ -d "${PROJECT_DIR}/node_modules" ]]; then
  find "${PROJECT_DIR}/node_modules" -maxdepth 3 -name "package.json" 2>/dev/null | sort > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_packages.list"
  { ls "${PROJECT_DIR}/node_modules/.bin/" 2>/dev/null || true; } | sort > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_bins.list"
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
  "project_dir": $(printf '%s' "${PROJECT_DIR}" | jq -Rs .),
  "command": $(printf '%s' "${COMMAND}" | jq -Rs .),
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
TYPOSQUAT_PATTERNS='(lod[bcdfghjklmnpqrstvwxyz]sh|lodahs|loadsh|lodashh|reacct|exprss|axois|babeel|webpackk|esliint|l0dash|m0ment|4xios|reqeusts|requets|djagno|numppy|panddas|pilliow|tensorfow|scikit-learnn|serde_jsonn|tokioo|reqwestt|clapp|github\.con/|githb\.com/|railss|sinatraa|nokogirri|log4jj|springframewrok|commons-collectionss|newtonsoft\.josn|serilogg|nunittt)'
if echo "${COMMAND}" | grep -qEi "${TYPOSQUAT_PATTERNS}"; then
  SUSPICIOUS=true
  REASONS+=("Package name matches known typosquatting patterns")
fi

if [[ "${SUSPICIOUS}" == "true" ]]; then
  REASON_STR=$(printf '%s; ' "${REASONS[@]}")
  jq -nc --arg reason "safedeps: ${REASON_STR%%; }" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
fi

# --- Phase 2 advisory gate — ledger enforcement -------------------------------
# For commands that name specific packages, require an entry in the approved-
# spec ledger. Miss/expired → block with a structured message that names the
# exact `safedeps check` command the caller (agent or human) should run next.
#
# Conservative: only block when at least one pkg@spec token is parseable. Bare
# `npm install` (lockfile install) falls through to the v1 reorg checks.

SAFEDEPS_LEDGER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ledger/ledger.sh"
SAFEDEPS_REPO_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/safedeps"

guard_detect_ecosystem() {
  local cmd="$1"
  local scan_cmd

  scan_cmd=$(command_scan_text "${cmd}")
  if echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)(npm|pnpm|yarn|npx)([[:space:]]|$)'; then
    printf 'npm'
  elif echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)(pip3?|poetry|uv|pipenv|((python3?|py)[[:space:]]+-m[[:space:]]+pip))([[:space:]]|$)'; then
    printf 'pypi'
  elif echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)cargo([[:space:]]|$)'; then
    printf 'crates.io'
  elif echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)go([[:space:]]|$)'; then
    printf 'go'
  elif echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)(gem|bundle)([[:space:]]|$)'; then
    printf 'rubygems'
  elif echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)mvn([[:space:]]|$)'; then
    printf 'maven'
  elif echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)dotnet([[:space:]]|$)'; then
    printf 'nuget'
  else
    printf ''
  fi
}

guard_extract_specs() {
  # Echo one "pkg<TAB>spec" line per pkg@spec token found in the command.
  # Captures @scope/name@spec and bare-name@spec forms.
  local cmd="$1"
  echo "${cmd}" \
    | grep -oE '(@[a-zA-Z0-9._/-]+/)?[a-zA-Z][a-zA-Z0-9._-]*@[a-zA-Z0-9._^~|<>=*+-]+' \
    | while IFS= read -r token; do
        local pkg spec
        if [[ "${token}" =~ ^(@[^@]+)@(.+)$ ]]; then
          pkg="${BASH_REMATCH[1]}"
          spec="${BASH_REMATCH[2]}"
        else
          pkg="${token%@*}"
          spec="${token##*@}"
        fi
        printf '%s\t%s\n' "${pkg}" "${spec}"
      done
}

LEDGER_ECOSYSTEM=$(guard_detect_ecosystem "${COMMAND}")
LEDGER_SPECS=()
while IFS= read -r ledger_spec_line; do
  [[ -z "${ledger_spec_line}" ]] && continue
  LEDGER_SPECS+=("${ledger_spec_line}")
done < <(guard_extract_specs "${COMMAND}")

if [[ -n "${LEDGER_ECOSYSTEM}" && ${#LEDGER_SPECS[@]} -gt 0 && -f "${SAFEDEPS_LEDGER_LIB}" ]]; then
  # shellcheck source=../lib/ledger/ledger.sh
  source "${SAFEDEPS_LEDGER_LIB}"

  GUARD_BLOCKED_CMDS=()
  for entry in "${LEDGER_SPECS[@]}"; do
    pkg="${entry%%$'\t'*}"
    spec="${entry##*$'\t'}"
    [[ -z "${pkg}" || -z "${spec}" ]] && continue
    if ! safedeps_ledger_check "${LEDGER_ECOSYSTEM}" "${pkg}" "${spec}" 2>/dev/null \
        | jq -e '.approved == true' >/dev/null 2>&1; then
      GUARD_BLOCKED_CMDS+=("safedeps check ${LEDGER_ECOSYSTEM} ${pkg}@${spec}")
    fi
  done

  if [[ ${#GUARD_BLOCKED_CMDS[@]} -gt 0 ]]; then
    NEXT_CMD=""
    for ((i = 0; i < ${#GUARD_BLOCKED_CMDS[@]}; i++)); do
      if [[ -z "${NEXT_CMD}" ]]; then
        NEXT_CMD="${GUARD_BLOCKED_CMDS[$i]}"
      else
        NEXT_CMD="${NEXT_CMD} && ${GUARD_BLOCKED_CMDS[$i]}"
      fi
    done
    REASON_JSON=$(jq -nc \
      --arg next "${NEXT_CMD}" \
      --arg ecosystem "${LEDGER_ECOSYSTEM}" \
      '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("safedeps: install not approved (ecosystem=" + $ecosystem + ") — run `" + $next + "` first, then retry the install using the approved version (see install_hint in the check output).")
        }
      }')
    printf '%s\n' "${REASON_JSON}"
    exit 0
  fi
fi

# Write current state atomically for PostToolUse (V-004: single file prevents TOCTOU)
CURRENT_STATE=$(jq -n --arg sid "${SNAPSHOT_ID}" --arg pdir "${PROJECT_DIR}" --arg dhash "${DIR_HASH}" \
  '{snapshot_id: $sid, project_dir: $pdir, dir_hash: $dhash}')
write_state_file "${GUARD_DIR}/current_state" "${CURRENT_STATE}"

# Allow the command to proceed — PostToolUse will verify the result
exit 0
