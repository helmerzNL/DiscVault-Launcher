#!/bin/sh
#
# Guards against env drift between DiscVault and the launcher.
#
# DiscVault's reference stack deployment (app/deploy/next/.env.example plus the
# matching docker-compose.yml) is the contract the launcher has to satisfy. When
# DiscVault adds a runtime variable there and the launcher does not plumb it
# through, the setting silently has no effect on launcher-managed installs --
# which is exactly how JWT_SECRET went missing from next-worker.
#
# Run with: sh launcher/tests/test-env-coverage.sh
#
# The DiscVault checkout is optional: set DISCVAULT_REPO to point at it, or place
# it next to this repository. Without it the upstream comparison is skipped and
# only the launcher-internal consistency checks run.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"

ENTRYPOINT="$ROOT/launcher/entrypoint.sh"
LAUNCHER_COMPOSE="$ROOT/stack/docker-compose.launcher.yml"
STANDALONE_COMPOSE="$ROOT/stack/docker-compose.yml"
ENV_EXAMPLE="$ROOT/stack/.env.example"

FAILURES=0
CHECKS=0

fail_check() {
  printf 'FAIL %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

ok_check() {
  printf 'ok   %s\n' "$1"
}

# Variables the launcher owns itself, or that DiscVault's reference compose maps
# to a launcher-specific equivalent. Each entry needs a reason.
is_launcher_owned() {
  case "$1" in
    # Host paths and ports: the launcher proxies and uses its own *_HOST names.
    DISCVAULT_DATA_DIR|DISCVAULT_NEXT_POSTGRES_DATA|DISCVAULT_NEXT_API_PORT) return 0 ;;
    # Network name: the launcher exposes this as DISCVAULT_NETWORK.
    DISCVAULT_NEXT_NETWORK_NAME) return 0 ;;
    # Version reporting: deliberately left to the image, which bakes the real
    # build version. Mapping the launcher's coarse "v26" would report less.
    BUILD_VERSION) return 0 ;;
    # Image selector consumed by the launcher itself: it resolves this into the
    # DISCVAULT_IMAGE the compose services actually reference.
    DISCVAULT_NEXT_IMAGE) return 0 ;;
    # Injected into the compose file through the __DISCVAULT_MCP_PORTS__
    # substitution rather than as a ${VAR} reference, because publishing the
    # port at all is optional.
    DISCVAULT_NEXT_MCP_PORT) return 0 ;;
    *) return 1 ;;
  esac
}

env_keys_from_file() {
  sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$1" | sort -u
}

service_block() {
  # Print the environment: block of one compose service.
  awk -v svc="  $1:" '
    $0 == svc { in_svc = 1; next }
    in_svc && /^  [a-z]/ { in_svc = 0 }
    in_svc && /^    environment:/ { in_env = 1; next }
    in_svc && in_env && /^    [a-z]/ { in_env = 0 }
    in_svc && in_env { print }
  ' "$2"
}

echo '# launcher self-consistency'

# Every variable in stack/.env.example must be consumed by at least one compose
# file, otherwise the example documents a setting that does nothing.
for key in $(env_keys_from_file "$ENV_EXAMPLE"); do
  CHECKS=$((CHECKS + 1))
  if grep -q "\${$key" "$STANDALONE_COMPOSE"; then
    ok_check ".env.example $key is used by stack/docker-compose.yml"
  else
    fail_check ".env.example documents $key but stack/docker-compose.yml never reads it"
  fi
done

# The API and the worker both call validate_runtime_secrets() at startup, so
# both need the same secrets, and the key-encryption secret must match or
# credentials encrypted by one process cannot be read by the other.
for compose in "$LAUNCHER_COMPOSE" "$STANDALONE_COMPOSE"; do
  for svc in next-api next-worker; do
    for key in JWT_SECRET DISCVAULT_NEXT_KEY_ENCRYPTION_KEY; do
      CHECKS=$((CHECKS + 1))
      if service_block "$svc" "$compose" | grep -q "^ *$key:"; then
        ok_check "$(basename "$compose") $svc sets $key"
      else
        fail_check "$(basename "$compose") $svc is missing $key"
      fi
    done
  done
done

echo '# upstream DiscVault reference deployment'

DISCVAULT_REPO="${DISCVAULT_REPO:-$ROOT/../DiscVault}"
UPSTREAM_ENV="$DISCVAULT_REPO/app/deploy/next/.env.example"

if [ ! -f "$UPSTREAM_ENV" ]; then
  printf 'skip DiscVault checkout not found at %s; set DISCVAULT_REPO to enable\n' "$DISCVAULT_REPO"
else
  for key in $(env_keys_from_file "$UPSTREAM_ENV"); do
    CHECKS=$((CHECKS + 1))
    if is_launcher_owned "$key"; then
      ok_check "$key is launcher-owned (see is_launcher_owned)"
    elif grep -q "\b$key\b" "$ENTRYPOINT" && grep -q "\${$key" "$LAUNCHER_COMPOSE"; then
      ok_check "$key is plumbed through entrypoint and launcher compose"
    elif grep -q "\b$key\b" "$ENTRYPOINT"; then
      fail_check "$key is set in entrypoint.sh but never mapped into a service in docker-compose.launcher.yml"
    else
      fail_check "$key exists in DiscVault's reference .env.example but the launcher does not handle it"
    fi
  done
fi

printf '\n%s checks, %s failures\n' "$CHECKS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
