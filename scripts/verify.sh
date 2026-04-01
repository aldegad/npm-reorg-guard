#!/usr/bin/env bash
# npm-reorg-guard: PostToolUse hook
# Verifies lock file changes after npm install and performs reorg (rollback) if suspicious

set -euo pipefail

GUARD_DIR="${HOME}/.npm-reorg-guard"
SNAPSHOT_DIR="${GUARD_DIR}/snapshots"
STATE_LOCK_DIR="${GUARD_DIR}/state.lock"

mkdir -p "${GUARD_DIR}" "${SNAPSHOT_DIR}"

if ! command -v jq >/dev/null 2>&1; then
  echo "npm-reorg-guard: jq is not installed; skipping verify hook." >&2
  exit 0
fi

acquire_state_lock() {
  local attempts=0

  while ! mkdir "${STATE_LOCK_DIR}" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ ${attempts} -ge 100 ]]; then
      echo "npm-reorg-guard: could not acquire state lock; skipping verify hook." >&2
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

hash_file() {
  local file_path="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file_path}" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file_path}" | cut -d' ' -f1
  else
    echo ""
  fi
}

files_differ() {
  local left_path="$1"
  local right_path="$2"
  local left_hash
  local right_hash

  if [[ ! -f "${left_path}" ]] && [[ ! -f "${right_path}" ]]; then
    return 1
  fi

  if [[ ! -f "${left_path}" ]] || [[ ! -f "${right_path}" ]]; then
    return 0
  fi

  if command -v cmp >/dev/null 2>&1; then
    ! cmp -s "${left_path}" "${right_path}"
    return
  fi

  left_hash=$(hash_file "${left_path}")
  right_hash=$(hash_file "${right_path}")

  if [[ -n "${left_hash}" ]] && [[ -n "${right_hash}" ]]; then
    [[ "${left_hash}" != "${right_hash}" ]]
    return
  fi

  ! diff -q "${left_path}" "${right_path}" >/dev/null 2>&1
}

read_confirmed_snapshot() {
  local confirmed_snapshot=""

  acquire_state_lock
  if [[ -f "${GUARD_DIR}/confirmed" ]]; then
    confirmed_snapshot=$(cat "${GUARD_DIR}/confirmed" 2>/dev/null || true)
  fi
  release_state_lock; STATE_LOCK_HELD=false

  printf '%s' "${confirmed_snapshot}"
}

confirm_snapshot() {
  local snapshot_id="$1"

  acquire_state_lock; STATE_LOCK_HELD=true
  write_state_file "${GUARD_DIR}/confirmed" "${snapshot_id}"
  release_state_lock; STATE_LOCK_HELD=false
}

collect_protected_snapshot_ids() {
  local snapshot_id
  local parent_snapshot_id
  local meta_file
  local seen=()

  snapshot_id=$(read_confirmed_snapshot)

  while [[ -n "${snapshot_id}" ]]; do
    local already_seen="false"
    local seen_id

    for seen_id in "${seen[@]}"; do
      if [[ "${seen_id}" == "${snapshot_id}" ]]; then
        already_seen="true"
        break
      fi
    done

    if [[ "${already_seen}" == "true" ]]; then
      break
    fi

    seen+=("${snapshot_id}")
    printf '%s\n' "${snapshot_id}"

    meta_file="${SNAPSHOT_DIR}/${snapshot_id}_meta.json"
    if [[ ! -f "${meta_file}" ]]; then
      break
    fi

    parent_snapshot_id=$(jq -r '.parent_snapshot_id // empty' "${meta_file}" 2>/dev/null || true)
    snapshot_id="${parent_snapshot_id}"
  done
}

snapshot_is_protected() {
  local target_snapshot_id="$1"
  shift

  local protected_snapshot_id
  for protected_snapshot_id in "$@"; do
    if [[ "${protected_snapshot_id}" == "${target_snapshot_id}" ]]; then
      return 0
    fi
  done

  return 1
}

cleanup_old_snapshots() {
  local protected_snapshot_ids=()
  local protected_snapshot_id
  local old_meta
  local old_id
  local removable_seen=0

  while IFS= read -r protected_snapshot_id; do
    if [[ -n "${protected_snapshot_id}" ]]; then
      protected_snapshot_ids+=("${protected_snapshot_id}")
    fi
  done < <(collect_protected_snapshot_ids)

  while IFS= read -r old_meta; do
    old_id=$(jq -r '.snapshot_id // empty' "${old_meta}" 2>/dev/null || true)

    if [[ -z "${old_id}" ]]; then
      continue
    fi

    if snapshot_is_protected "${old_id}" "${protected_snapshot_ids[@]}"; then
      continue
    fi

    removable_seen=$((removable_seen + 1))
    if [[ ${removable_seen} -le 10 ]]; then
      continue
    fi

    rm -f "${SNAPSHOT_DIR}/${old_id}"_*
  done < <(ls -t "${SNAPSHOT_DIR}"/*_meta.json 2>/dev/null || true)
}

restore_node_modules() {
  if ! command -v npm >/dev/null 2>&1; then
    ROLLBACK_WARNINGS+=("npm is not installed; node_modules was not reinstalled")
    return
  fi

  if [[ -f "${PROJECT_DIR}/package-lock.json" ]]; then
    if (cd "${PROJECT_DIR}" && npm ci >/dev/null 2>&1); then
      return
    fi
    ROLLBACK_WARNINGS+=("npm ci failed during rollback; retrying with npm install")
  fi

  if (cd "${PROJECT_DIR}" && rm -rf node_modules && npm install >/dev/null 2>&1); then
    return
  fi

  ROLLBACK_WARNINGS+=("node_modules reinstall failed; review the project manually")
}

# Read tool input from stdin
INPUT=$(cat)

# Only process Bash tool results
TOOL_NAME=$(echo "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
if [[ "${TOOL_NAME}" != "Bash" ]]; then
  exit 0
fi

STATE_LOCK_HELD=true
acquire_state_lock
trap '[ "${STATE_LOCK_HELD:-}" = "true" ] && release_state_lock; STATE_LOCK_HELD=false' EXIT

# Check if we have a pending snapshot to verify
if [[ ! -f "${GUARD_DIR}/current_snapshot_id" ]]; then
  exit 0
fi

SNAPSHOT_ID=$(cat "${GUARD_DIR}/current_snapshot_id")
PROJECT_DIR=$(cat "${GUARD_DIR}/current_project_dir" 2>/dev/null || pwd)

# Clean up current marker
rm -f "${GUARD_DIR}/current_snapshot_id"
rm -f "${GUARD_DIR}/current_project_dir"
release_state_lock; STATE_LOCK_HELD=false

# Verify snapshot exists
META_FILE="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_meta.json"
if [[ ! -f "${META_FILE}" ]]; then
  exit 0
fi

# --- Begin Reorg Verification ---

SUSPICIOUS=false
REASONS=()
ROLLBACK_WARNINGS=()

# Function: check for suspicious postinstall scripts in new/changed dependencies
check_postinstall_scripts() {
  local pkg_json="${PROJECT_DIR}/package.json"
  local changed_lock=false
  local lock_file

  if [[ ! -f "${pkg_json}" ]]; then
    return
  fi

  for lock_file in "package-lock.json" "pnpm-lock.yaml" "yarn.lock"; do
    if files_differ "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${lock_file}" "${PROJECT_DIR}/${lock_file}"; then
      changed_lock=true
      break
    fi
  done

  if [[ "${changed_lock}" != "true" ]] && ! files_differ "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_package.json" "${pkg_json}"; then
    return
  fi

  # Check node_modules for new packages with install scripts
  if [[ -d "${PROJECT_DIR}/node_modules" ]]; then
    # Find packages with postinstall/preinstall scripts
    local script_packages
    local old_pkg_listing="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_packages.list"
    if [[ -f "${old_pkg_listing}" ]]; then
      script_packages=$(find "${PROJECT_DIR}/node_modules" -maxdepth 3 -name "package.json" 2>/dev/null | sort | comm -13 "${old_pkg_listing}" - | head -50)
    else
      script_packages=$(find "${PROJECT_DIR}/node_modules" -maxdepth 3 -name "package.json" 2>/dev/null | head -50)
    fi

    for pkg in ${script_packages}; do
      # Check for suspicious install hooks
      local has_preinstall
      local has_postinstall
      local has_install
      local pkg_name

      has_preinstall=$(jq -r '.scripts.preinstall // empty' "${pkg}" 2>/dev/null)
      has_postinstall=$(jq -r '.scripts.postinstall // empty' "${pkg}" 2>/dev/null)
      has_install=$(jq -r '.scripts.install // empty' "${pkg}" 2>/dev/null)
      pkg_name=$(jq -r '.name // "unknown"' "${pkg}" 2>/dev/null)

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
  local lock_file

  for lock_file in "${lock_files[@]}"; do
    local current="${PROJECT_DIR}/${lock_file}"
    local snapshot="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${lock_file}"

    if [[ ! -f "${current}" ]] || [[ ! -f "${snapshot}" ]]; then
      continue
    fi

    # Compare content directly so mtime manipulation cannot bypass verification.
    if ! files_differ "${snapshot}" "${current}"; then
      continue
    fi

    # Lock file changed — analyze the diff
    if [[ "${lock_file}" == "package-lock.json" ]]; then
      local suspicious_urls
      local insecure_urls
      local new_deps

      # Check for resolved URLs pointing to non-standard registries
      suspicious_urls=$(diff "${snapshot}" "${current}" 2>/dev/null | grep '^>' | grep '"resolved"' | grep -viE 'registry\.npmjs\.org|registry\.yarnpkg\.com' | head -5)
      if [[ -n "${suspicious_urls}" ]]; then
        SUSPICIOUS=true
        REASONS+=("Lock file contains resolved URLs from non-standard registries")
      fi

      # Check for git:// or http:// (non-https) resolved URLs
      insecure_urls=$(diff "${snapshot}" "${current}" 2>/dev/null | grep '^>' | grep '"resolved"' | grep -iE '(git://|http://)' | head -5)
      if [[ -n "${insecure_urls}" ]]; then
        SUSPICIOUS=true
        REASONS+=("Lock file contains insecure (non-HTTPS) resolved URLs")
      fi

      # Check for a very large number of new dependencies (potential dependency confusion)
      new_deps=$(diff "${snapshot}" "${current}" 2>/dev/null | grep '^>' | grep -c '"resolved"' || echo "0")
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
    local new_bins
    local old_bin_listing="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_bins.list"
    if [[ -f "${old_bin_listing}" ]]; then
      new_bins=$(ls "${PROJECT_DIR}/node_modules/.bin/" 2>/dev/null | sort | comm -13 "${old_bin_listing}" - | head -20)
    else
      new_bins=$(ls "${PROJECT_DIR}/node_modules/.bin/" 2>/dev/null | head -20)
    fi

    for bin in ${new_bins}; do
      # Check if it's a binary file (not a script)
      if file "${bin}" 2>/dev/null | grep -qiE '(executable|shared object|Mach-O|ELF)'; then
        local bin_name
        bin_name=$(basename "${bin}")
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
  # REORG: Rollback to last confirmed safe snapshot
  ROLLBACK_SNAPSHOT_ID=$(read_confirmed_snapshot)
  if [[ -z "${ROLLBACK_SNAPSHOT_ID}" ]] || [[ ! -f "${SNAPSHOT_DIR}/${ROLLBACK_SNAPSHOT_ID}_meta.json" ]]; then
    ROLLBACK_SNAPSHOT_ID="${SNAPSHOT_ID}"
  fi

  LOCK_FILES=("package-lock.json" "pnpm-lock.yaml" "yarn.lock")
  ROLLED_BACK=()

  for lock_file in "${LOCK_FILES[@]}"; do
    snapshot_lock="${SNAPSHOT_DIR}/${ROLLBACK_SNAPSHOT_ID}_${lock_file}"
    current_lock="${PROJECT_DIR}/${lock_file}"

    if [[ ! -f "${snapshot_lock}" ]]; then
      continue
    fi

    if files_differ "${snapshot_lock}" "${current_lock}"; then
      cp "${snapshot_lock}" "${current_lock}"
      ROLLED_BACK+=("${lock_file}")
    fi
  done

  # Restore package.json if it was modified
  rollback_package_json="${SNAPSHOT_DIR}/${ROLLBACK_SNAPSHOT_ID}_package.json"
  current_package_json="${PROJECT_DIR}/package.json"
  if [[ -f "${rollback_package_json}" ]] && files_differ "${rollback_package_json}" "${current_package_json}"; then
    cp "${rollback_package_json}" "${current_package_json}"
    ROLLED_BACK+=("package.json")
  fi

  restore_node_modules
  cleanup_old_snapshots

  REASON_STR=$(printf '%s; ' "${REASONS[@]}")
  ROLLED_BACK_STR=$(printf '%s, ' "${ROLLED_BACK[@]}")
  WARNING_STR=""
  if [[ ${#ROLLBACK_WARNINGS[@]} -gt 0 ]]; then
    WARNING_STR=$(printf '%s; ' "${ROLLBACK_WARNINGS[@]}")
  fi

  # Log the reorg event
  cat >> "${GUARD_DIR}/reorg.log" << LOG_EOF
[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] REORG executed
  Snapshot: ${SNAPSHOT_ID}
  Rollback snapshot: ${ROLLBACK_SNAPSHOT_ID}
  Project: ${PROJECT_DIR}
  Reasons: ${REASON_STR%%; }
  Rolled back: ${ROLLED_BACK_STR%, }
  Rollback warnings: ${WARNING_STR%%; }
LOG_EOF

  cat << EOF
{"systemMessage": "npm-reorg-guard: 의심스러운 패키지 변경 감지, 마지막으로 confirmed 된 안전 스냅샷으로 롤백했습니다.\n\n감지된 문제:\n${REASON_STR%%; }\n\n롤백 기준 스냅샷: ${ROLLBACK_SNAPSHOT_ID}\n롤백된 파일: ${ROLLED_BACK_STR%, }\n${WARNING_STR:+\n추가 경고:\n${WARNING_STR%%; }}\n\n상세 로그: ${GUARD_DIR}/reorg.log"}
EOF
  exit 0
fi

confirm_snapshot "${SNAPSHOT_ID}"
cleanup_old_snapshots

exit 0
