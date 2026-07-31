# shellcheck shell=sh
#
# Pure helper functions for the DiscVault launcher.
#
# This file is sourced by launcher/entrypoint.sh and by launcher/tests/*.sh.
# Keep it free of side effects: no logging, no Docker calls, no writes outside
# the file paths that are passed in explicitly. Everything that talks to Docker
# or to the registry lives in entrypoint.sh.

DISCVAULT_IMAGE_REPO="${DISCVAULT_IMAGE_REPO:-ghcr.io/helmerznl/discvault}"

# Resolve a configured image value to a full image reference.
#
# Anything containing a "/" is already a full reference (registry/repo, with an
# optional :tag and/or @sha256: digest) and is passed through untouched. The
# remaining values are bare shorthands:
#
#   auto, prod              -> :latest   (not real tags; they mean "the stable channel")
#   latest, stable, v26,
#   v26-beta, beta, dev,
#   v26.7.7, ...            -> the tag of the same name on the DiscVault repo
#
# Treating unknown bare values as tags matters: before this, anything outside a
# small hardcoded list was returned verbatim, which produced an invalid image
# reference and made the launcher exit before nginx ever started.
resolve_stack_image_alias() {
  value="$1"

  case "$value" in
    */*)
      printf '%s' "$value"
      return 0
      ;;
  esac

  case "$value" in
    '')
      printf '%s' ''
      ;;
    auto|prod)
      printf '%s' "$DISCVAULT_IMAGE_REPO:latest"
      ;;
    *)
      printf '%s' "$DISCVAULT_IMAGE_REPO:$value"
      ;;
  esac
}

normalize_digest() {
  value="$1"
  case "$value" in
    sha256:*) printf '%s' "$value" ;;
    *) printf 'sha256:%s' "$value" ;;
  esac
}

image_repo_from_ref() {
  ref_without_digest="${1%@*}"
  last_segment="${ref_without_digest##*/}"
  if [ "${last_segment#*:}" != "$last_segment" ]; then
    printf '%s' "${ref_without_digest%:*}"
  else
    printf '%s' "$ref_without_digest"
  fi
}

is_digest_pinned_ref() {
  case "$1" in
    *@sha256:*) return 0 ;;
    *) return 1 ;;
  esac
}

pinned_digest_from_ref() {
  normalize_digest "${1##*@}"
}

set_env() {
  key="$1"
  value="$2"
  file="$3"
  tmp="${file}.tmp"
  grep -v "^${key}=" "$file" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
}

ensure_env() {
  key="$1"
  value="$2"
  file="$3"
  if ! grep -q "^${key}=" "$file" 2>/dev/null; then
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

env_file_value() {
  key="$1"
  file="$2"
  grep "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

ensure_non_empty_env() {
  key="$1"
  value="$2"
  file="$3"
  current="$(env_file_value "$key" "$file")"
  if [ -z "$current" ]; then
    set_env "$key" "$value" "$file"
  fi
}

is_secret_env_key() {
  key="$1"
  case "$key" in
    *PASSWORD*|*SECRET*|*TOKEN*|*PRIVATE_KEY*|*ACCESS_KEY*|*API_KEY*|*PASSKEY*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Resolve one configured image variable.
#
# The container environment is authoritative: the launcher image always defines
# both DISCVAULT_NEXT_IMAGE and DISCVAULT_IMAGE via ENV, and Unraid passes them
# on every start. An empty value therefore means "no override", not "look it up
# somewhere else" -- otherwise a value written to /config/stack.env once could
# never be cleared from the UI again, permanently pinning the stack.
#
# Sets two globals for the caller: CONFIGURED_IMAGE_SOURCE (container-env or
# stack.env) and CONFIGURED_IMAGE_VALUE (possibly empty).
#
# shellcheck disable=SC2034 # Both globals are read by the sourcing script.
resolve_configured_image_var() {
  key="$1"
  file="$2"

  eval "configured_var_present=\${${key}+set}"
  if [ "${configured_var_present:-}" = set ]; then
    eval "CONFIGURED_IMAGE_VALUE=\${${key}}"
    CONFIGURED_IMAGE_SOURCE='container-env'
  else
    CONFIGURED_IMAGE_VALUE="$(env_file_value "$key" "$file")"
    CONFIGURED_IMAGE_SOURCE='stack.env'
  fi
}
