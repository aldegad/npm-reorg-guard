#!/bin/bash
# Generic repo security profile + gitleaks config resolution.
# Absorbed from kuma-studio scripts/security/repo-profile.sh and made generic:
# the private profile is detected by a "-private" suffix convention instead of a
# hard-coded repo name, and overrides accept both SAFEDEPS_* and legacy KUMA_* env.

safedeps_repo_profile() {
  local repo_root="${1:?repo root required}"
  local override="${SAFEDEPS_REPO_PROFILE:-${KUMA_SECURITY_REPO_PROFILE:-}}"

  case "$override" in
    public|private)
      printf '%s\n' "$override"
      return 0
      ;;
    "")
      ;;
    *)
      printf 'ERROR: repo profile override must be "public" or "private", got: %s\n' "$override" >&2
      return 64
      ;;
  esac

  local origin_url repo_leaf
  origin_url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
  repo_leaf="$(basename "$repo_root")"

  # Convention: a repo whose origin slug or directory leaf ends in "-private" is
  # the private profile (e.g. kuma-studio-private). Everything else is public.
  if [[ "$origin_url" =~ (^|[/:-])[A-Za-z0-9._-]*-private(\.git)?$ ]] || [[ "$repo_leaf" == *-private ]]; then
    printf 'private\n'
    return 0
  fi

  printf 'public\n'
}

safedeps_gitleaks_config() {
  local repo_root="${1:?repo root required}"
  local profile="${2:?profile required}"
  local override="${SAFEDEPS_GITLEAKS_CONFIG:-${KUMA_GITLEAKS_CONFIG:-}}"

  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi

  case "$profile" in
    private)
      printf '%s/.gitleaks.private.toml\n' "$repo_root"
      ;;
    public)
      printf '%s/.gitleaks.toml\n' "$repo_root"
      ;;
    *)
      printf 'ERROR: unknown security profile: %s\n' "$profile" >&2
      return 64
      ;;
  esac
}
