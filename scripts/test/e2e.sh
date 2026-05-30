#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-e2e.XXXXXX")
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  rm -rf "${tmp_root}"
}
trap cleanup EXIT

port_file="${tmp_root}/port"
state_file="${tmp_root}/state.json"
printf '%s\n' '{"vulnerable":[]}' > "${state_file}"
node scripts/test/fixture-provider.mjs "${port_file}" "${state_file}" &
server_pid=$!

for _ in {1..50}; do
  [[ -s "${port_file}" ]] && break
  sleep 0.1
done
[[ -s "${port_file}" ]] || fail "fixture provider starts"
port=$(cat "${port_file}")

export SAFEDEPS_HOME="${tmp_root}/safe"
export SAFEDEPS_OSV_API_URL="http://127.0.0.1:${port}/osv/v1/query"
export SAFEDEPS_KEV_CATALOG_URL="http://127.0.0.1:${port}/kev.json"
export SAFEDEPS_GHSA_API_URL="http://127.0.0.1:${port}/advisories"
export SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS=0

clean_json=$(./bin/safedeps --json check npm fixture-clean@1.0.0)
[[ "$(jq -r '.result' <<< "${clean_json}")" == "clean" ]] || fail "clean fixture approved"
pass "clean advisory approval"

patched_json=$(./bin/safedeps --json check npm fixture-vuln@1.0.0)
[[ "$(jq -r '.result' <<< "${patched_json}")" == "patched_available" ]] || fail "patched fixture narrows"
[[ "$(jq -r '.suggested_spec' <<< "${patched_json}")" == "1.0.1" ]] || fail "patched fixture suggests fixed version"
pass "patched advisory narrowing"

set +e
unpatched_json=$(./bin/safedeps --json check npm fixture-unpatched@1.0.0)
unpatched_status=$?
kev_json=$(./bin/safedeps --json check npm fixture-kev@1.0.0)
kev_status=$?
set -e
[[ "${unpatched_status}" -eq 2 ]] || fail "unpatched fixture exits 2"
[[ "$(jq -r '.result' <<< "${unpatched_json}")" == "cve_unpatched" ]] || fail "unpatched fixture reports cve_unpatched"
[[ "${kev_status}" -eq 3 ]] || fail "kev fixture exits 3"
[[ "$(jq -r '.result' <<< "${kev_json}")" == "kev_hard_block" ]] || fail "kev fixture reports kev_hard_block"
pass "block classifications"

project_dir="${tmp_root}/project"
mkdir -p "${project_dir}"
printf '{"dependencies":{}}\n' > "${project_dir}/package.json"
hook_allow=$(
  scripts/safedeps-pre-guard.sh <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-vuln@1.0.1"},"cwd":"${project_dir}"}
EOF
)
[[ -z "${hook_allow}" ]] || fail "hook allows narrowed approved spec"
pass "hook allows approved narrowed spec"

printf '%s\n' '{"vulnerable":["fixture-clean@1.0.0"]}' > "${state_file}"
recheck_json=$(./bin/safedeps --json re-check)
[[ "$(jq -r '.revoked | length' <<< "${recheck_json}")" == "1" ]] || fail "re-check revokes newly vulnerable spec"
[[ "$(jq -r '.revoked[0].package' <<< "${recheck_json}")" == "fixture-clean" ]] || fail "re-check revoked expected package"
pass "re-check revocation"

legacy_home="${tmp_root}/legacy"
target_home="${tmp_root}/migrated"
mkdir -p "${legacy_home}/approved-specs"
printf 'legacy\n' > "${legacy_home}/approved-specs/example.json"
migrate_json=$(SAFEDEPS_LEGACY_HOME="${legacy_home}" SAFEDEPS_HOME="${target_home}" ./bin/safedeps --json migrate)
[[ "$(jq -r '.migrated' <<< "${migrate_json}")" == "true" ]] || fail "legacy state migrated"
[[ -f "${target_home}/approved-specs/example.json" ]] || fail "legacy state copied"
[[ ! -e "${legacy_home}" ]] || fail "legacy root archived"
pass "legacy state migration"

installer_home="${tmp_root}/installer-home"
mkdir -p "${installer_home}/.claude" "${installer_home}/.codex"
cat > "${installer_home}/.claude/settings.json" <<EOF
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"${installer_home}/.claude/skills/npm-reorg-guard/scripts/guard.sh"}]}],"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"${installer_home}/.claude/skills/npm-reorg-guard/scripts/verify.sh"}]}]}}
EOF
HOME="${installer_home}" node scripts/install/install-safedeps-hooks.mjs >/dev/null
jq -e --arg pre "~/.claude/skills/safedeps/scripts/safedeps-pre-guard.sh" '
  [.hooks.PreToolUse[]?.hooks[]?.command] | index($pre)
' "${installer_home}/.claude/settings.json" >/dev/null || fail "installer writes new pre hook"
jq -e --arg post "~/.claude/skills/safedeps/scripts/safedeps-post-verify.sh" '
  [.hooks.PostToolUse[]?.hooks[]?.command] | index($post)
' "${installer_home}/.claude/settings.json" >/dev/null || fail "installer writes new post hook"
jq -e --arg pre "~/.codex/skills/safedeps/scripts/safedeps-pre-guard.sh" '
  [.hooks.PreToolUse[]?.hooks[]?.command] | index($pre)
' "${installer_home}/.codex/hooks.json" >/dev/null || fail "installer writes codex pre hook"
jq -e --arg post "~/.codex/skills/safedeps/scripts/safedeps-post-verify.sh" '
  [.hooks.PostToolUse[]?.hooks[]?.command] | index($post)
' "${installer_home}/.codex/hooks.json" >/dev/null || fail "installer writes codex post hook"
if jq -e '[.. | strings] | any(contains("npm-reorg-guard"))' "${installer_home}/.claude/settings.json" >/dev/null; then
  fail "installer removes legacy hook"
fi
pass "installer legacy hook cleanup"

printf 'e2e passed\n'
