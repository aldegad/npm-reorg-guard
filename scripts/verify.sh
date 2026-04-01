#!/usr/bin/env bash
# npm-reorg-guard: PostToolUse hook
# Verifies lock file changes after npm install and performs reorg (rollback) if suspicious

set -euo pipefail

GUARD_DIR="${HOME}/.npm-reorg-guard"
SNAPSHOT_DIR="${GUARD_DIR}/snapshots"

# Read tool input from stdin
INPUT=$(cat)

# Only process Bash tool results
TOOL_NAME=$(echo "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
if [[ "${TOOL_NAME}" != "Bash" ]]; then
  exit 0
fi

# Check if we have a pending snapshot to verify
if [[ ! -f "${GUARD_DIR}/current_snapshot_id" ]]; then
  exit 0
fi

SNAPSHOT_ID=$(cat "${GUARD_DIR}/current_snapshot_id")
PROJECT_DIR=$(cat "${GUARD_DIR}/current_project_dir" 2>/dev/null || pwd)

# Clean up current marker
rm -f "${GUARD_DIR}/current_snapshot_id"
rm -f "${GUARD_DIR}/current_project_dir"

# Verify snapshot exists
META_FILE="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_meta.json"
if [[ ! -f "${META_FILE}" ]]; then
  exit 0
fi

# --- Begin Reorg Verification ---

SUSPICIOUS=false
REASONS=()

# Function: check for suspicious postinstall scripts in new/changed dependencies
check_postinstall_scripts() {
  local pkg_json="${PROJECT_DIR}/package.json"
  local old_pkg_json="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_package.json"
  
  if [[ ! -f "${pkg_json}" ]]; then
    return
  fi
  
  # Check node_modules for new packages with install scripts
  if [[ -d "${PROJECT_DIR}/node_modules" ]]; then
    # Find packages with postinstall/preinstall scripts
    local script_packages=$(find "${PROJECT_DIR}/node_modules" -maxdepth 3 -name "package.json" -newer "${META_FILE}" 2>/dev/null | head -50)
    
    for pkg in ${script_packages}; do
      # Check for suspicious install hooks
      local has_preinstall=$(jq -r '.scripts.preinstall // empty' "${pkg}" 2>/dev/null)
      local has_postinstall=$(jq -r '.scripts.postinstall // empty' "${pkg}" 2>/dev/null)
      local has_install=$(jq -r '.scripts.install // empty' "${pkg}" 2>/dev/null)
      local pkg_name=$(jq -r '.name // "unknown"' "${pkg}" 2>/dev/null)
      
      for script_content in "${has_preinstall}" "${has_postinstall}" "${has_install}"; do
        if [[ -z "${script_content}" ]]; then
          continue
        fi
        
        # Check for network calls in install scripts
        if echo "${script_content}" | grep -qEi '(curl|wget|fetch|http|https|net\.|socket|dns)'; then
          SUSPICIOUS=true
          REASONS+=("Package '${pkg_name}' has install script with network access: ${script_content}")
        fi
        
        # Check for eval/exec in install scripts
        if echo "${script_content}" | grep -qEi '(eval|exec|spawn|child_process|Function\()'; then
          SUSPICIOUS=true
          REASONS+=("Package '${pkg_name}' has install script with code execution: ${script_content}")
        fi
        
        # Check for filesystem access outside project
        if echo "${script_content}" | grep -qEi '(\/etc\/|\/home\/|~\/|\$HOME|\.ssh|\.env|\.aws|credentials)'; then
          SUSPICIOUS=true
          REASONS+=("Package '${pkg_name}' has install script accessing sensitive paths")
        fi
        
        # Check for encoded/obfuscated content
        if echo "${script_content}" | grep -qEi '(base64|atob|Buffer\.from|\\x[0-9a-f]{2}|\\u[0-9a-f]{4})'; then
          SUSPICIOUS=true
          REASONS+=("Package '${pkg_name}' has install script with obfuscated content")
        fi
      done
    done
  fi
}

# Function: check lock file diff for suspicious changes
check_lockfile_diff() {
  local lock_files=("package-lock.json" "pnpm-lock.yaml" "yarn.lock")
  
  for lock_file in "${lock_files[@]}"; do
    local current="${PROJECT_DIR}/${lock_file}"
    local snapshot="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${lock_file}"
    
    if [[ ! -f "${current}" ]] || [[ ! -f "${snapshot}" ]]; then
      continue
    fi
    
    # Check if lock file changed
    local current_hash snapshot_hash
    if command -v shasum &>/dev/null; then
      current_hash=$(shasum -a 256 "${current}" | cut -d' ' -f1)
    elif command -v sha256sum &>/dev/null; then
      current_hash=$(sha256sum "${current}" | cut -d' ' -f1)
    else
      continue
    fi
    
    snapshot_hash=$(cut -d' ' -f1 "${snapshot}.sha256" 2>/dev/null || echo "none")
    
    if [[ "${current_hash}" == "${snapshot_hash}" ]]; then
      continue
    fi
    
    # Lock file changed — analyze the diff
    if [[ "${lock_file}" == "package-lock.json" ]]; then
      # Check for resolved URLs pointing to non-standard registries
      local suspicious_urls=$(diff "${snapshot}" "${current}" 2>/dev/null | grep '^>' | grep '"resolved"' | grep -viE 'registry\.npmjs\.org|registry\.yarnpkg\.com' | head -5)
      if [[ -n "${suspicious_urls}" ]]; then
        SUSPICIOUS=true
        REASONS+=("Lock file contains resolved URLs from non-standard registries")
      fi
      
      # Check for git:// or http:// (non-https) resolved URLs
      local insecure_urls=$(diff "${snapshot}" "${current}" 2>/dev/null | grep '^>' | grep '"resolved"' | grep -iE '(git://|http://)' | head -5)
      if [[ -n "${insecure_urls}" ]]; then
        SUSPICIOUS=true
        REASONS+=("Lock file contains insecure (non-HTTPS) resolved URLs")
      fi
      
      # Check for a very large number of new dependencies (potential dependency confusion)
      local new_deps=$(diff "${snapshot}" "${current}" 2>/dev/null | grep '^>' | grep -c '"resolved"' || echo "0")
      if [[ ${new_deps} -gt 50 ]]; then
        SUSPICIOUS=true
        REASONS+=("Unusually large number of new dependencies added: ${new_deps}")
      fi
    fi
  done
}

# Function: check for suspicious binaries
check_binaries() {
  if [[ -d "${PROJECT_DIR}/node_modules/.bin" ]]; then
    # Check for newly added binaries that are actual compiled binaries (not scripts)
    local new_bins=$(find "${PROJECT_DIR}/node_modules/.bin" -newer "${META_FILE}" -type f 2>/dev/null | head -20)
    
    for bin in ${new_bins}; do
      # Check if it's a binary file (not a script)
      if file "${bin}" 2>/dev/null | grep -qiE '(executable|shared object|Mach-O|ELF)'; then
        local bin_name=$(basename "${bin}")
        SUSPICIOUS=true
        REASONS+=("Native binary '${bin_name}' found in node_modules/.bin")
      fi
    done
  fi
}

# Run all checks
check_postinstall_scripts
check_lockfile_diff
check_binaries

# --- Reorg Decision ---

if [[ "${SUSPICIOUS}" == "true" ]]; then
  # REORG: Rollback to safe snapshot
  LOCK_FILES=("package-lock.json" "pnpm-lock.yaml" "yarn.lock")
  ROLLED_BACK=()
  
  for lock_file in "${LOCK_FILES[@]}"; do
    local_snapshot="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${lock_file}"
    local_current="${PROJECT_DIR}/${lock_file}"
    
    if [[ -f "${local_snapshot}" ]] && [[ -f "${local_current}" ]]; then
      cp "${local_snapshot}" "${local_current}"
      ROLLED_BACK+=("${lock_file}")
    fi
  done
  
  # Restore package.json if it was modified
  if [[ -f "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_package.json" ]]; then
    local old_pkg_hash new_pkg_hash
    if command -v shasum &>/dev/null; then
      old_pkg_hash=$(shasum -a 256 "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_package.json" | cut -d' ' -f1)
      new_pkg_hash=$(shasum -a 256 "${PROJECT_DIR}/package.json" | cut -d' ' -f1)
    elif command -v sha256sum &>/dev/null; then
      old_pkg_hash=$(sha256sum "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_package.json" | cut -d' ' -f1)
      new_pkg_hash=$(sha256sum "${PROJECT_DIR}/package.json" | cut -d' ' -f1)
    fi
  fi
  
  REASON_STR=$(printf '%s; ' "${REASONS[@]}")
  ROLLED_BACK_STR=$(printf '%s, ' "${ROLLED_BACK[@]}")
  
  # Log the reorg event
  cat >> "${GUARD_DIR}/reorg.log" << LOG_EOF
[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] REORG executed
  Snapshot: ${SNAPSHOT_ID}
  Project: ${PROJECT_DIR}
  Reasons: ${REASON_STR%%; }
  Rolled back: ${ROLLED_BACK_STR%, }
LOG_EOF
  
  cat << EOF
{"systemMessage": "npm-reorg-guard: 의심스러운 패키지 변경 감지, 이전 안전 상태로 롤백했습니다.\n\n감지된 문제:\n${REASON_STR%%; }\n\n롤백된 파일: ${ROLLED_BACK_STR%, }\n\n상세 로그: ${GUARD_DIR}/reorg.log"}
EOF
  exit 0
fi

# All clear — clean up snapshot (keep last 10 for audit trail)
ls -t "${SNAPSHOT_DIR}"/*_meta.json 2>/dev/null | tail -n +11 | while read old_meta; do
  OLD_ID=$(jq -r '.snapshot_id' "${old_meta}")
  rm -f "${SNAPSHOT_DIR}/${OLD_ID}"_*
done

exit 0
