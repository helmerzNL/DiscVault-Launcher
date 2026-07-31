#!/bin/sh
#
# Tests for the pure image-resolution helpers in launcher/lib.sh.
#
# Run with: sh launcher/tests/test-image-resolution.sh

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
LIB="$SCRIPT_DIR/../lib.sh"

# shellcheck source=launcher/lib.sh
. "$LIB"

REPO='ghcr.io/helmerznl/discvault'
FAILURES=0
CHECKS=0

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

expect_eq() {
  label="$1"
  actual="$2"
  expected="$3"
  CHECKS=$((CHECKS + 1))
  if [ "$actual" = "$expected" ]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$label" "$expected" "$actual"
    FAILURES=$((FAILURES + 1))
  fi
}

expect_status() {
  label="$1"
  expected="$2"
  shift 2
  CHECKS=$((CHECKS + 1))
  if "$@"; then
    actual=0
  else
    actual=1
  fi
  if [ "$actual" = "$expected" ]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n       expected exit %s, got %s\n' "$label" "$expected" "$actual"
    FAILURES=$((FAILURES + 1))
  fi
}

echo '# resolve_stack_image_alias'

# "auto" and "prod" are not real tags; they mean "the stable channel".
expect_eq 'auto -> :latest' "$(resolve_stack_image_alias auto)" "$REPO:latest"
expect_eq 'prod -> :latest' "$(resolve_stack_image_alias prod)" "$REPO:latest"

# Bare values that ARE real DiscVault tags must resolve to the tag of the same
# name. Before the fix only latest/v26/beta/v26-beta were known and v26 wrongly
# aliased to :latest; everything else was returned verbatim as an invalid ref,
# which made the launcher exit before nginx started.
expect_eq 'latest -> :latest' "$(resolve_stack_image_alias latest)" "$REPO:latest"
expect_eq 'stable -> :stable' "$(resolve_stack_image_alias stable)" "$REPO:stable"
expect_eq 'v26 -> :v26' "$(resolve_stack_image_alias v26)" "$REPO:v26"
expect_eq 'beta -> :beta' "$(resolve_stack_image_alias beta)" "$REPO:beta"
expect_eq 'v26-beta -> :v26-beta' "$(resolve_stack_image_alias v26-beta)" "$REPO:v26-beta"
expect_eq 'dev -> :dev' "$(resolve_stack_image_alias dev)" "$REPO:dev"
expect_eq 'v26.7.7 -> :v26.7.7' "$(resolve_stack_image_alias v26.7.7)" "$REPO:v26.7.7"

# Anything containing a slash is already a full reference.
expect_eq 'full ref passthrough' \
  "$(resolve_stack_image_alias "$REPO:v26-beta")" "$REPO:v26-beta"
expect_eq 'digest-pinned ref passthrough' \
  "$(resolve_stack_image_alias "$REPO:v26-beta@sha256:abc")" "$REPO:v26-beta@sha256:abc"
expect_eq 'third-party registry passthrough' \
  "$(resolve_stack_image_alias 'registry.example.com/team/discvault:custom')" \
  'registry.example.com/team/discvault:custom'
expect_eq 'empty stays empty' "$(resolve_stack_image_alias '')" ''

echo '# update_channel_for_ref'

# The two launcher channels and their deprecated aliases.
expect_eq ':latest -> stable' "$(update_channel_for_ref "$REPO:latest")" 'stable'
expect_eq ':v26 -> stable' "$(update_channel_for_ref "$REPO:v26")" 'stable'
expect_eq ':stable -> stable' "$(update_channel_for_ref "$REPO:stable")" 'stable'
expect_eq ':beta -> beta' "$(update_channel_for_ref "$REPO:beta")" 'beta'
expect_eq ':v26-beta -> beta' "$(update_channel_for_ref "$REPO:v26-beta")" 'beta'

# Release snapshots are cut from main, so they are the stable channel.
expect_eq ':v26.7.7 -> stable' "$(update_channel_for_ref "$REPO:v26.7.7")" 'stable'

# Anything we cannot classify stays "auto", which hands the decision back to
# the app's own heuristic rather than asserting something we do not know.
expect_eq ':dev -> auto' "$(update_channel_for_ref "$REPO:dev")" 'auto'
expect_eq 'untagged ref -> auto' "$(update_channel_for_ref "$REPO")" 'auto'
expect_eq 'digest-only ref -> auto' "$(update_channel_for_ref "$REPO@sha256:abc")" 'auto'
expect_eq 'pinned :beta keeps its channel' \
  "$(update_channel_for_ref "$REPO:beta@sha256:abc")" 'beta'
expect_eq 'third-party registry -> auto' \
  "$(update_channel_for_ref 'registry.example.com/team/discvault:latest')" 'auto'

echo '# digest helpers'

expect_eq 'normalize bare digest' "$(normalize_digest abc123)" 'sha256:abc123'
expect_eq 'normalize prefixed digest' "$(normalize_digest sha256:abc123)" 'sha256:abc123'

expect_status 'tag ref is not pinned' 1 is_digest_pinned_ref "$REPO:v26-beta"
expect_status 'tag+digest ref is pinned' 0 is_digest_pinned_ref "$REPO:v26-beta@sha256:abc"
expect_status 'digest-only ref is pinned' 0 is_digest_pinned_ref "$REPO@sha256:abc"

expect_eq 'digest from tag+digest ref' \
  "$(pinned_digest_from_ref "$REPO:v26-beta@sha256:abc")" 'sha256:abc'
expect_eq 'digest from digest-only ref' \
  "$(pinned_digest_from_ref "$REPO@sha256:abc")" 'sha256:abc'

echo '# image_repo_from_ref'

expect_eq 'repo from tagged ref' "$(image_repo_from_ref "$REPO:v26-beta")" "$REPO"
expect_eq 'repo from untagged ref' "$(image_repo_from_ref "$REPO")" "$REPO"
expect_eq 'repo from pinned ref' "$(image_repo_from_ref "$REPO:v26-beta@sha256:abc")" "$REPO"
expect_eq 'repo from registry with port' \
  "$(image_repo_from_ref 'registry.example.com:5000/team/discvault:tag')" \
  'registry.example.com:5000/team/discvault'

echo '# env file helpers'

ENV_FILE="$TMP_DIR/stack.env"
: > "$ENV_FILE"
set_env DISCVAULT_IMAGE "$REPO:v26-beta@sha256:deadbeef" "$ENV_FILE"
expect_eq 'set_env then read back' \
  "$(env_file_value DISCVAULT_IMAGE "$ENV_FILE")" "$REPO:v26-beta@sha256:deadbeef"

set_env DISCVAULT_IMAGE "$REPO:dev" "$ENV_FILE"
expect_eq 'set_env replaces rather than appends' \
  "$(env_file_value DISCVAULT_IMAGE "$ENV_FILE")" "$REPO:dev"
expect_eq 'set_env keeps a single line' \
  "$(grep -c '^DISCVAULT_IMAGE=' "$ENV_FILE")" '1'

expect_eq 'value with = survives round-trip' \
  "$(set_env SOME_KEY 'a=b=c' "$ENV_FILE"; env_file_value SOME_KEY "$ENV_FILE")" 'a=b=c'

expect_status 'password key is secret' 0 is_secret_env_key POSTGRES_PASSWORD
expect_status 'jwt secret key is secret' 0 is_secret_env_key JWT_SECRET
expect_status 'key-encryption key is secret' 0 is_secret_env_key DISCVAULT_NEXT_KEY_ENCRYPTION_KEY
expect_status 'image key is not secret' 1 is_secret_env_key DISCVAULT_IMAGE

echo '# resolve_configured_image_var precedence'

# This is the regression that froze stacks in the field: the launcher image
# always defines DISCVAULT_IMAGE and Unraid passes it on every start, so an
# empty value must mean "no value" -- not "fall back to whatever was written to
# stack.env once".
: > "$ENV_FILE"
set_env DISCVAULT_IMAGE "$REPO:v26-beta@sha256:deadbeef" "$ENV_FILE"

DISCVAULT_IMAGE=''
export DISCVAULT_IMAGE
resolve_configured_image_var DISCVAULT_IMAGE "$ENV_FILE"
expect_eq 'empty container env wins over stored pin' "$CONFIGURED_IMAGE_VALUE" ''
expect_eq 'empty container env reports its source' "$CONFIGURED_IMAGE_SOURCE" 'container-env'

DISCVAULT_IMAGE="$REPO:dev"
export DISCVAULT_IMAGE
resolve_configured_image_var DISCVAULT_IMAGE "$ENV_FILE"
expect_eq 'set container env wins over stored pin' "$CONFIGURED_IMAGE_VALUE" "$REPO:dev"
expect_eq 'set container env reports its source' "$CONFIGURED_IMAGE_SOURCE" 'container-env'

unset DISCVAULT_IMAGE
resolve_configured_image_var DISCVAULT_IMAGE "$ENV_FILE"
expect_eq 'stack.env is used only when the variable is absent' \
  "$CONFIGURED_IMAGE_VALUE" "$REPO:v26-beta@sha256:deadbeef"
expect_eq 'absent variable reports stack.env as source' "$CONFIGURED_IMAGE_SOURCE" 'stack.env'

printf '\n%s checks, %s failures\n' "$CHECKS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
