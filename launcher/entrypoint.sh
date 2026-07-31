#!/bin/sh
set -eu

# shellcheck source=launcher/lib.sh
. "${DISCVAULT_LAUNCHER_LIB:-/opt/discvault-launcher/lib.sh}"

LOG_FILE=""
ROLLOUT_LOCK_DIR=""
ROLLOUT_LOCK_TIMEOUT="${DISCVAULT_ROLLOUT_LOCK_TIMEOUT:-300}"
BOOT_LOG_RETENTION="${DISCVAULT_BOOT_LOG_RETENTION:-50}"

case "$ROLLOUT_LOCK_TIMEOUT" in
  ''|*[!0-9]*)
    ROLLOUT_LOCK_TIMEOUT=300
    ;;
esac
case "$BOOT_LOG_RETENTION" in
  ''|*[!0-9]*)
    BOOT_LOG_RETENTION=50
    ;;
esac

log() {
  timestamp="$(date -Iseconds)"
  line="$timestamp $*"
  printf '%s\n' "$line"
  if [ -n "$LOG_FILE" ]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
  fi
}

fail() {
  log "$*"
  exit 1
}

random_secret() {
  openssl rand -hex 32
}

image_id() {
  docker image inspect "$1" --format '{{.Id}}' 2>/dev/null || true
}

remote_digest_for_ref() {
  inspect_output="$(docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
  digest="$(printf '%s\n' "$inspect_output" | grep -Eo 'sha256:[0-9a-f]{64}' | head -n 1 || true)"
  if [ -z "$digest" ] || [ "$digest" = "<nil>" ]; then
    return 1
  fi
  normalize_digest "$digest"
}

local_digest_for_ref() {
  ref="$1"
  desired_repo="$2"
  repo_digests="$(docker image inspect "$ref" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null || true)"
  if [ -z "$repo_digests" ]; then
    return 0
  fi

  digest_line="$(printf '%s\n' "$repo_digests" | grep "^${desired_repo}@sha256:" | head -n 1 || true)"
  if [ -z "$digest_line" ]; then
    digest_line="$(printf '%s\n' "$repo_digests" | grep '@sha256:' | head -n 1 || true)"
  fi
  if [ -z "$digest_line" ]; then
    return 0
  fi

  printf '%s' "${digest_line##*@}"
}

container_image_id() {
  docker inspect "$1" --format '{{.Image}}' 2>/dev/null || true
}

container_config_image() {
  docker inspect "$1" --format '{{.Config.Image}}' 2>/dev/null || true
}

container_digest_for_image_id() {
  image_identifier="$1"
  desired_repo="$2"
  repo_digests="$(docker image inspect "$image_identifier" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null || true)"
  if [ -z "$repo_digests" ]; then
    return 0
  fi

  digest_line="$(printf '%s\n' "$repo_digests" | grep "^${desired_repo}@sha256:" | head -n 1 || true)"
  if [ -z "$digest_line" ]; then
    digest_line="$(printf '%s\n' "$repo_digests" | grep '@sha256:' | head -n 1 || true)"
  fi
  if [ -z "$digest_line" ]; then
    return 0
  fi

  printf '%s' "${digest_line##*@}"
}

image_revision_label() {
  docker image inspect "$1" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true
}

running_service_container_ids() {
  docker ps -q \
    --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --filter "label=com.docker.compose.service=$1"
}

log_service_runtime_state() {
  phase="$1"
  service="$2"
  desired_repo="$3"
  ids="$(running_service_container_ids "$service")"
  if [ -z "$ids" ]; then
    log "Service state $phase service=$service running_container=none"
    return 1
  fi

  for id in $ids; do
    runtime_image_id="$(container_image_id "$id")"
    runtime_config_image="$(container_config_image "$id")"
    runtime_digest="$(container_digest_for_image_id "$runtime_image_id" "$desired_repo")"
    revision="$(image_revision_label "$runtime_image_id")"
    log "Service state $phase service=$service container=$id config_image=$runtime_config_image image_id=${runtime_image_id:-unknown} digest=${runtime_digest:-unknown} revision=${revision:-unknown}"
  done

  return 0
}

service_runtime_matches() {
  service="$1"
  desired_digest="$2"
  local_image_identifier="$3"
  desired_repo="$4"
  ids="$(running_service_container_ids "$service")"
  if [ -z "$ids" ]; then
    return 1
  fi

  for id in $ids; do
    runtime_image_id="$(container_image_id "$id")"
    runtime_digest="$(container_digest_for_image_id "$runtime_image_id" "$desired_repo")"
    if [ -z "$runtime_digest" ] || [ "$runtime_digest" != "$desired_digest" ]; then
      return 1
    fi
    if [ -n "$local_image_identifier" ] && [ "$runtime_image_id" != "$local_image_identifier" ]; then
      return 1
    fi
  done

  return 0
}

health_sha_from_next_api() {
  health_json="$(curl -fsS --max-time 10 http://next-api:5000/api/next/health 2>/dev/null || true)"
  if [ -z "$health_json" ]; then
    return 0
  fi
  printf '%s' "$health_json" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

require_non_empty_env() {
  key="$1"
  file="$2"
  current="$(env_file_value "$key" "$file")"
  if [ -z "$current" ]; then
    fail "Required launcher env $key is empty in $file"
  fi
}

# Compose interpolation prefers the process environment over --env-file, so a
# value can be correct in the env file and still reach the container empty. That
# is not hypothetical: launchers built before the env values were exported
# generated a POSTGRES_PASSWORD into stack.env, compose read the empty one from
# the container environment, and postgres crash-looped on "superuser password is
# not specified" -- surfacing only as "container is unhealthy". Check both.
require_secret_reaches_compose() {
  key="$1"
  file_value="$(env_file_value "$key" "$COMPOSE_ENV_FILE")"
  if [ -z "$file_value" ]; then
    fail "$key is empty in $COMPOSE_ENV_FILE; refusing to start the stack with an unusable secret"
  fi
  env_value="$(printenv "$key" 2>/dev/null || true)"
  if [ -z "$env_value" ]; then
    fail "$key is set in $COMPOSE_ENV_FILE but empty in the launcher process environment; Compose would interpolate the empty value"
  fi
  if [ "$env_value" != "$file_value" ]; then
    fail "$key differs between $COMPOSE_ENV_FILE and the launcher process environment; Compose would use the process value"
  fi
}

export_env_from_file() {
  key="$1"
  file="$2"
  value="$(env_file_value "$key" "$file")"
  export "$key=$value"
}

log_env_snapshot() {
  for key in "$@"; do
    value="$(printenv "$key" 2>/dev/null || true)"
    if is_secret_env_key "$key"; then
      if [ -n "$value" ]; then
        log "ENV $key=<redacted>"
      else
        log "ENV $key=<empty redacted>"
      fi
    elif [ -n "$value" ]; then
      log "ENV $key=$value"
    else
      log "ENV $key=<empty>"
    fi
  done
}

prune_boot_logs() {
  log_dir="$1"
  keep="$2"
  if [ "$keep" -le 0 ]; then
    return 0
  fi
  old_logs="$(ls -1t "$log_dir"/launcher-boot-*.log 2>/dev/null | sed -n "$((keep + 1)),\$p" || true)"
  if [ -z "$old_logs" ]; then
    return 0
  fi
  for log_path in $old_logs; do
    rm -f "$log_path" || true
  done
}

release_rollout_lock() {
  if [ -n "$ROLLOUT_LOCK_DIR" ] && [ -d "$ROLLOUT_LOCK_DIR" ]; then
    rm -rf "$ROLLOUT_LOCK_DIR" || true
  fi
}

acquire_rollout_lock() {
  ROLLOUT_LOCK_DIR="$CONFIG_DIR/.launcher-rollout-lock"
  start_epoch="$(date +%s)"

  while ! mkdir "$ROLLOUT_LOCK_DIR" 2>/dev/null; do
    lock_pid="$(cat "$ROLLOUT_LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
      log "Removing stale rollout lock at $ROLLOUT_LOCK_DIR held by pid $lock_pid"
      rm -rf "$ROLLOUT_LOCK_DIR" || true
      continue
    fi

    now_epoch="$(date +%s)"
    waited="$((now_epoch - start_epoch))"
    if [ "$waited" -ge "$ROLLOUT_LOCK_TIMEOUT" ]; then
      fail "Timed out waiting ${ROLLOUT_LOCK_TIMEOUT}s for rollout lock at $ROLLOUT_LOCK_DIR"
    fi
    sleep 1
  done

  printf '%s\n' "$$" > "$ROLLOUT_LOCK_DIR/pid"
  log "Acquired rollout lock $ROLLOUT_LOCK_DIR with pid $$"
}

# Ask PostgreSQL whether the credentials the launcher hands out actually work.
#
# The stack healthcheck cannot answer this: pg_isready reports that the server
# responded, including when the response is an authentication error. So a data
# directory initialised with a different password leaves postgres "healthy"
# while next-api restart-loops on "password authentication failed", and Compose
# reports only "dependency failed to start".
#
# The password goes in over stdin rather than as an argument, so it never
# appears in the launcher's process list or in docker's own logging.
postgres_probe() {
  pg_id="$1"
  printf '%s\n' "$POSTGRES_PASSWORD" | docker exec -i "$pg_id" sh -c '
    read -r pw
    PGPASSWORD="$pw" exec psql -h 127.0.0.1 -p 5432 -U "$1" -d "$2" -tAc "select 1"
  ' _ "$POSTGRES_USER" "$POSTGRES_DB" 2>&1
}

sync_postgres_password() {
  pg_id="$1"
  # The official image trusts local superuser connections, so the launcher can
  # set the password without knowing the old one.
  escaped="$(printf '%s' "$POSTGRES_PASSWORD" | sed "s/'/''/g")"
  printf "ALTER USER \"%s\" WITH PASSWORD '%s';\n" "$POSTGRES_USER" "$escaped" \
    | docker exec -i "$pg_id" psql -U postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1
}

verify_postgres_credentials() {
  attempts="${DISCVAULT_POSTGRES_PROBE_ATTEMPTS:-12}"
  interval="${DISCVAULT_POSTGRES_PROBE_INTERVAL:-5}"
  attempt=1
  probe_output=""

  while [ "$attempt" -le "$attempts" ]; do
    pg_id="$(running_service_container_ids postgres | head -n 1)"
    if [ -n "$pg_id" ]; then
      if probe_output="$(postgres_probe "$pg_id")"; then
        log "PostgreSQL accepted the configured credentials for user $POSTGRES_USER"
        return 0
      fi

      # Quote PostgreSQL's own words: it is the same message that shows up in
      # next-api's traceback, which is where operators meet this first.
      probe_summary="$(printf '%s' "$probe_output" | tr '\n' ' ')"

      case "$probe_output" in
        *"authentication failed"*|*"no password supplied"*|*"role \"$POSTGRES_USER\" does not exist"*)
          if [ "$SYNC_POSTGRES_PASSWORD" = "true" ]; then
            log "DISCVAULT_POSTGRES_SYNC_PASSWORD=true; resynchronising the PostgreSQL password for user $POSTGRES_USER"
            if sync_postgres_password "$pg_id"; then
              log "Resynchronised the PostgreSQL password for user $POSTGRES_USER from the launcher configuration"
              return 0
            fi
            fail "Could not resynchronise the PostgreSQL password for user $POSTGRES_USER. Set POSTGRES_PASSWORD to the value $POSTGRES_DATA_DIR was initialised with, or empty that directory to start over."
          fi
          fail "PostgreSQL rejected the configured credentials for user $POSTGRES_USER: $probe_summary -- POSTGRES_PASSWORD only applies when the data directory is first initialised, so $POSTGRES_DATA_DIR was created with a different password. Either set POSTGRES_PASSWORD to that original value, set DISCVAULT_POSTGRES_SYNC_PASSWORD=true to let the launcher run ALTER USER for you, or empty the data directory to start over."
          ;;
      esac
    fi

    attempt=$((attempt + 1))
    [ "$attempt" -le "$attempts" ] && sleep "$interval"
  done

  fail "PostgreSQL did not accept connections after $attempts attempts; last probe reported: $probe_output"
}

verify_stack_after_deploy() {
  desired_digest="$1"
  desired_repo="$2"
  check_health_sha="$3"
  expected_revision=""

  for service in next-api next-worker next-mcp; do
    ids="$(running_service_container_ids "$service")"
    if [ -z "$ids" ]; then
      fail "Post-deploy verification failed: service $service has no running containers"
    fi

    for id in $ids; do
      runtime_image_id="$(container_image_id "$id")"
      runtime_digest="$(container_digest_for_image_id "$runtime_image_id" "$desired_repo")"
      revision="$(image_revision_label "$runtime_image_id")"
      log "Post-deploy service=$service container=$id image_id=${runtime_image_id:-unknown} digest=${runtime_digest:-unknown} revision=${revision:-unknown}"

      if [ -z "$runtime_digest" ] || [ "$runtime_digest" != "$desired_digest" ]; then
        fail "Post-deploy verification failed: service $service container $id digest ${runtime_digest:-missing} does not match desired $desired_digest"
      fi

      if [ "$service" = "next-api" ]; then
        if [ -z "$revision" ]; then
          fail "Post-deploy verification failed: next-api image revision label org.opencontainers.image.revision is empty"
        fi
        if [ -z "$expected_revision" ]; then
          expected_revision="$revision"
        elif [ "$expected_revision" != "$revision" ]; then
          fail "Post-deploy verification failed: next-api revision mismatch ($expected_revision vs $revision)"
        fi
      elif [ -n "$expected_revision" ] && [ -n "$revision" ] && [ "$expected_revision" != "$revision" ]; then
        fail "Post-deploy verification failed: $service revision $revision does not match next-api revision $expected_revision"
      fi
    done
  done

  if [ "$check_health_sha" = "true" ]; then
    health_sha="$(health_sha_from_next_api)"
    log "Post-deploy next-api health.sha=${health_sha:-missing}"
    if [ -z "$health_sha" ]; then
      fail "Post-deploy verification failed: could not read /api/next/health sha"
    fi
    if [ -n "$expected_revision" ] && [ "$health_sha" != "$expected_revision" ]; then
      fail "Post-deploy verification failed: health.sha $health_sha does not match image revision $expected_revision"
    fi
  fi
}

CONFIG_DIR="${DISCVAULT_LAUNCHER_CONFIG:-/config}"
ENV_FILE="$CONFIG_DIR/stack.env"
COMPOSE_ENV_FILE="$CONFIG_DIR/.compose.env"
COMPOSE_FILE="$CONFIG_DIR/docker-compose.yml"
LAST_STACK_DIGEST_FILE="$CONFIG_DIR/last-stack-digest"
PROJECT_NAME="${DISCVAULT_PROJECT_NAME:-discvault_stack}"
NETWORK_NAME="${DISCVAULT_NETWORK:-discvault-stack}"
RP_ORIGINS_VALUE="${RP_ORIGINS:-${RP_ORIGIN:-http://localhost:${DISCVAULT_WEB_PORT:-6080}}}"
PACKAGED_STACK_IMAGE="${DISCVAULT_LAUNCHER_STACK_IMAGE:-}"
PACKAGED_STACK_DIGEST="${DISCVAULT_LAUNCHER_STACK_DIGEST:-}"
FORCE_RECREATE_ON_PULL="${DISCVAULT_FORCE_RECREATE_ON_PULL:-true}"
ALWAYS_RECREATE_STACK="${DISCVAULT_ALWAYS_RECREATE_STACK:-false}"
CHECK_HEALTH_SHA="${DISCVAULT_CHECK_HEALTH_SHA:-true}"
SYNC_POSTGRES_PASSWORD="${DISCVAULT_POSTGRES_SYNC_PASSWORD:-false}"
POSTGRES_DATA_DIR="${DISCVAULT_POSTGRES_DATA_DIR_HOST:-/mnt/user/appdata/discvault-postgres}"

# Overridable so the rollout can be exercised outside the image; the defaults are
# the paths the Dockerfile installs to.
COMPOSE_TEMPLATE="${DISCVAULT_LAUNCHER_COMPOSE_TEMPLATE:-/opt/discvault-launcher/docker-compose.yml}"
NGINX_TEMPLATE="${DISCVAULT_LAUNCHER_NGINX_TEMPLATE:-/opt/discvault-launcher/nginx.conf.template}"
NGINX_CONF="${DISCVAULT_LAUNCHER_NGINX_CONF:-/etc/nginx/http.d/default.conf}"

mkdir -p "$CONFIG_DIR"
touch "$ENV_FILE"
LOG_DIR="$CONFIG_DIR/logs"
mkdir -p "$LOG_DIR"
BOOT_TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/launcher-boot-$BOOT_TS-$$.log"
touch "$LOG_FILE"
prune_boot_logs "$LOG_DIR" "$BOOT_LOG_RETENTION"

log "Using launcher config directory $CONFIG_DIR"
log "Using launcher env file $ENV_FILE"
log "Boot session log file $LOG_FILE"
log "Boot session log retention ${BOOT_LOG_RETENTION} sessions"

log_ignored_stored_override() {
  key="$1"
  value_source="$2"
  active_value="$3"
  stored_value="$(env_file_value "$key" "$ENV_FILE")"
  if [ "$value_source" = "container-env" ] && [ -n "$stored_value" ] && [ "$stored_value" != "$active_value" ]; then
    log "Ignoring stored $key=$stored_value from $ENV_FILE; container env is authoritative (now ${active_value:-<empty>})"
  fi
}

# The container environment wins over anything persisted in stack.env. Both
# variables are always defined by the launcher image, so an empty value means
# "no override" rather than "fall back to the stored value". Without this, an
# override written to stack.env once -- for example the digest pin the README
# used to recommend -- could never be cleared from the Unraid UI again, and the
# stack stayed frozen on that image forever.
resolve_configured_image_var DISCVAULT_NEXT_IMAGE "$ENV_FILE"
NEXT_IMAGE_SOURCE="$CONFIGURED_IMAGE_SOURCE"
configured_next_image_raw="$CONFIGURED_IMAGE_VALUE"
log_ignored_stored_override DISCVAULT_NEXT_IMAGE "$NEXT_IMAGE_SOURCE" "$configured_next_image_raw"

resolve_configured_image_var DISCVAULT_IMAGE "$ENV_FILE"
IMAGE_SOURCE="$CONFIGURED_IMAGE_SOURCE"
configured_image_raw="$CONFIGURED_IMAGE_VALUE"
log_ignored_stored_override DISCVAULT_IMAGE "$IMAGE_SOURCE" "$configured_image_raw"

configured_next_image="$(resolve_stack_image_alias "$configured_next_image_raw")"
configured_image="$(resolve_stack_image_alias "$configured_image_raw")"

# The Unraid channel dropdown. It sits below the explicit image overrides so a
# digest pin still wins, and above the packaged default so switching the
# dropdown works without also changing the launcher repository.
CONFIGURED_CHANNEL="${DISCVAULT_CHANNEL:-}"
CHANNEL_STACK_IMAGE=""
if [ -n "$CONFIGURED_CHANNEL" ] && [ "$CONFIGURED_CHANNEL" != "auto" ]; then
  CHANNEL_STACK_IMAGE="$(stack_image_for_channel "$CONFIGURED_CHANNEL")"
  if [ -z "$CHANNEL_STACK_IMAGE" ]; then
    log "WARNING: Unknown DISCVAULT_CHANNEL=$CONFIGURED_CHANNEL; expected latest or beta. Falling back to the launcher's packaged channel."
  fi
fi

if [ -n "$configured_next_image_raw" ] && [ "$configured_next_image_raw" != "auto" ]; then
  STACK_IMAGE="$configured_next_image"
  STACK_IMAGE_SOURCE="DISCVAULT_NEXT_IMAGE"
elif [ -n "$configured_image_raw" ] && [ "$configured_image_raw" != "auto" ]; then
  STACK_IMAGE="$configured_image"
  STACK_IMAGE_SOURCE="DISCVAULT_IMAGE"
elif [ -n "$CHANNEL_STACK_IMAGE" ]; then
  STACK_IMAGE="$CHANNEL_STACK_IMAGE"
  STACK_IMAGE_SOURCE="DISCVAULT_CHANNEL=$CONFIGURED_CHANNEL"
else
  STACK_IMAGE="${PACKAGED_STACK_IMAGE:-ghcr.io/helmerznl/discvault:latest}"
  STACK_IMAGE_SOURCE="packaged-default"
fi

if [ -z "$STACK_IMAGE" ]; then
  fail "No DiscVault image reference could be resolved"
fi

export DISCVAULT_IMAGE="$STACK_IMAGE"
if [ -n "$configured_next_image_raw" ]; then
  export DISCVAULT_NEXT_IMAGE="$configured_next_image"
fi

# Legacy single-container mode was removed: DiscVault dropped app/Dockerfile and
# now builds every channel -- including :latest -- from app/Dockerfile.v26, so
# every published image is the PostgreSQL-backed v26 stack. Keep accepting the
# old setting so existing configs do not break, but never act on it.
case "${DISCVAULT_DEPLOYMENT_MODE:-auto}" in
  auto|stack)
    ;;
  legacy)
    log "WARNING: DISCVAULT_DEPLOYMENT_MODE=legacy is no longer supported; every DiscVault channel is now the v26 stack. Continuing in stack mode."
    ;;
  *)
    log "WARNING: Ignoring unsupported DISCVAULT_DEPLOYMENT_MODE=${DISCVAULT_DEPLOYMENT_MODE:-}; continuing in stack mode."
    ;;
esac

set_env TZ "${TZ:-Europe/Amsterdam}" "$ENV_FILE"
set_env DISCVAULT_CHANNEL "$CONFIGURED_CHANNEL" "$ENV_FILE"
set_env DISCVAULT_IMAGE "${configured_image_raw:-auto}" "$ENV_FILE"
set_env DISCVAULT_NEXT_IMAGE "$configured_next_image_raw" "$ENV_FILE"
set_env DISCVAULT_DATA_DIR_HOST "${DISCVAULT_DATA_DIR_HOST:-/mnt/user/appdata/discvault}" "$ENV_FILE"
set_env DISCVAULT_POSTGRES_DATA_DIR_HOST "${DISCVAULT_POSTGRES_DATA_DIR_HOST:-/mnt/user/appdata/discvault-postgres}" "$ENV_FILE"
set_env DISCVAULT_NETWORK "$NETWORK_NAME" "$ENV_FILE"
set_env BUILD_VERSION "${BUILD_VERSION:-v26}" "$ENV_FILE"
set_env POSTGRES_DB "${POSTGRES_DB:-discvault_next}" "$ENV_FILE"
set_env POSTGRES_USER "${POSTGRES_USER:-discvault_next}" "$ENV_FILE"
set_env RP_ID "${RP_ID:-localhost}" "$ENV_FILE"
set_env RP_NAME "${RP_NAME:-DiscVault}" "$ENV_FILE"
set_env RP_ORIGINS "$RP_ORIGINS_VALUE" "$ENV_FILE"
set_env RP_ORIGIN "${RP_ORIGIN:-$RP_ORIGINS_VALUE}" "$ENV_FILE"
set_env DISCVAULT_NEXT_MCP_PORT "${DISCVAULT_NEXT_MCP_PORT:-}" "$ENV_FILE"
set_env DISCVAULT_NEXT_API_WORKERS "${DISCVAULT_NEXT_API_WORKERS:-2}" "$ENV_FILE"
set_env DISCVAULT_NEXT_API_TIMEOUT "${DISCVAULT_NEXT_API_TIMEOUT:-180}" "$ENV_FILE"
set_env DISCVAULT_WORKER_ID "${DISCVAULT_WORKER_ID:-next-worker-1}" "$ENV_FILE"
set_env DISCVAULT_WORKER_POLL_INTERVAL "${DISCVAULT_WORKER_POLL_INTERVAL:-2}" "$ENV_FILE"
set_env DISCVAULT_NEXT_ENABLE_TEST_RESET "${DISCVAULT_NEXT_ENABLE_TEST_RESET:-false}" "$ENV_FILE"
set_env LEGACY_AUTH_ENABLED "${LEGACY_AUTH_ENABLED:-false}" "$ENV_FILE"

# The launcher resolved the image tag itself, so it knows the channel. Without
# this the app falls back to a version heuristic in resolve_update_channel().
# An explicit value from the container env always wins.
if [ -n "${DISCVAULT_UPDATE_CHANNEL:-}" ]; then
  RESOLVED_UPDATE_CHANNEL="$DISCVAULT_UPDATE_CHANNEL"
  UPDATE_CHANNEL_SOURCE="container-env"
else
  RESOLVED_UPDATE_CHANNEL="$(update_channel_for_ref "$STACK_IMAGE")"
  UPDATE_CHANNEL_SOURCE="derived from $STACK_IMAGE"
fi
set_env DISCVAULT_UPDATE_CHANNEL "$RESOLVED_UPDATE_CHANNEL" "$ENV_FILE"
log "DiscVault update channel $RESOLVED_UPDATE_CHANNEL ($UPDATE_CHANNEL_SOURCE)"
set_env DISCVAULT_ADMIN_DEDUP_EXECUTE_ENABLED "${DISCVAULT_ADMIN_DEDUP_EXECUTE_ENABLED:-false}" "$ENV_FILE"

# Deliberately not generated when empty: key_encryption_secret() falls back to
# JWT_SECRET, so minting a separate key here would make MovieVault credentials
# that existing installs already encrypted under JWT_SECRET undecryptable.
set_env DISCVAULT_NEXT_KEY_ENCRYPTION_KEY "${DISCVAULT_NEXT_KEY_ENCRYPTION_KEY:-}" "$ENV_FILE"

if [ -n "${POSTGRES_PASSWORD:-}" ]; then
  set_env POSTGRES_PASSWORD "$POSTGRES_PASSWORD" "$ENV_FILE"
else
  ensure_non_empty_env POSTGRES_PASSWORD "$(random_secret)" "$ENV_FILE"
fi

if [ -n "${JWT_SECRET:-}" ]; then
  set_env JWT_SECRET "$JWT_SECRET" "$ENV_FILE"
else
  ensure_non_empty_env JWT_SECRET "$(random_secret)" "$ENV_FILE"
fi
require_non_empty_env POSTGRES_PASSWORD "$ENV_FILE"
require_non_empty_env JWT_SECRET "$ENV_FILE"
log "Verified launcher secrets are present in $ENV_FILE"

for key in \
  TZ \
  DISCVAULT_IMAGE \
  DISCVAULT_NEXT_IMAGE \
  DISCVAULT_DATA_DIR_HOST \
  DISCVAULT_POSTGRES_DATA_DIR_HOST \
  DISCVAULT_NETWORK \
  BUILD_VERSION \
  POSTGRES_DB \
  POSTGRES_USER \
  POSTGRES_PASSWORD \
  JWT_SECRET \
  DISCVAULT_NEXT_KEY_ENCRYPTION_KEY \
  RP_ID \
  RP_NAME \
  RP_ORIGIN \
  RP_ORIGINS \
  LEGACY_AUTH_ENABLED \
  DISCVAULT_UPDATE_CHANNEL \
  DISCVAULT_NEXT_MCP_PORT \
  DISCVAULT_NEXT_API_WORKERS \
  DISCVAULT_NEXT_API_TIMEOUT \
  DISCVAULT_WORKER_ID \
  DISCVAULT_WORKER_POLL_INTERVAL \
  DISCVAULT_NEXT_ENABLE_TEST_RESET \
  DISCVAULT_ADMIN_DEDUP_EXECUTE_ENABLED
do
  export_env_from_file "$key" "$ENV_FILE"
done
log "Exported launcher env file values for Docker Compose"
log_env_snapshot \
  DISCVAULT_CHANNEL \
  DISCVAULT_NEXT_IMAGE \
  DISCVAULT_IMAGE \
  DISCVAULT_DEPLOYMENT_MODE \
  DISCVAULT_FORCE_RECREATE_ON_PULL \
  DISCVAULT_ALWAYS_RECREATE_STACK \
  DISCVAULT_CHECK_HEALTH_SHA \
  DISCVAULT_POSTGRES_SYNC_PASSWORD \
  DISCVAULT_BOOT_LOG_RETENTION \
  DISCVAULT_ROLLOUT_LOCK_TIMEOUT \
  DISCVAULT_DATA_DIR_HOST \
  DISCVAULT_POSTGRES_DATA_DIR_HOST \
  DISCVAULT_NETWORK \
  DISCVAULT_PROJECT_NAME \
  RP_ID \
  RP_NAME \
  RP_ORIGIN \
  RP_ORIGINS \
  LEGACY_AUTH_ENABLED \
  DISCVAULT_UPDATE_CHANNEL \
  DISCVAULT_NEXT_ENABLE_TEST_RESET \
  DISCVAULT_ADMIN_DEDUP_EXECUTE_ENABLED \
  POSTGRES_DB \
  POSTGRES_USER \
  POSTGRES_PASSWORD \
  JWT_SECRET \
  DISCVAULT_NEXT_KEY_ENCRYPTION_KEY

# Compose interpolation prefers the process environment over --env-file.
# Re-apply the resolved image ref here so service images never fall back to "auto".
export DISCVAULT_IMAGE="$STACK_IMAGE"
if [ -n "$configured_next_image_raw" ]; then
  export DISCVAULT_NEXT_IMAGE="$configured_next_image"
fi

cp "$ENV_FILE" "$COMPOSE_ENV_FILE"
set_env DISCVAULT_IMAGE "$STACK_IMAGE" "$COMPOSE_ENV_FILE"
if [ -n "$configured_next_image_raw" ]; then
  set_env DISCVAULT_NEXT_IMAGE "$configured_next_image" "$COMPOSE_ENV_FILE"
fi
log "Prepared compose env file $COMPOSE_ENV_FILE with resolved DISCVAULT_IMAGE=$STACK_IMAGE"

COMPOSE_UP_SERVICES="postgres next-api next-worker next-mcp"
if [ -n "${DISCVAULT_NEXT_MCP_PORT:-}" ]; then
  DISCVAULT_MCP_PORTS='    ports:
      - "'"$DISCVAULT_NEXT_MCP_PORT"':6090"'
  log "Publishing DiscVault MCP direct host port $DISCVAULT_NEXT_MCP_PORT"
else
  DISCVAULT_MCP_PORTS=""
  log "DiscVault MCP direct host port disabled; use the launcher proxy at /mcp"
fi
awk -v mcp_ports="$DISCVAULT_MCP_PORTS" '{
  if ($0 ~ /__DISCVAULT_MCP_PORTS__/) {
    print mcp_ports
  } else {
    print
  }
}' "$COMPOSE_TEMPLATE" > "$COMPOSE_FILE"
DISCVAULT_MCP_LOCATIONS='    location = /mcp-health {
        proxy_pass http://next-mcp:6090/health;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto $disc_vault_forwarded_proto;
        proxy_cache off;
    }

    location /mcp {
        proxy_pass http://next-mcp:6090;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto $disc_vault_forwarded_proto;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_cache off;
        proxy_read_timeout 180s;
        proxy_send_timeout 180s;
    }'
awk -v mcp_locations="$DISCVAULT_MCP_LOCATIONS" '{
  if ($0 ~ /__DISCVAULT_MCP_LOCATIONS__/) {
    print mcp_locations
  } else {
    print
  }
}' "$NGINX_TEMPLATE" > "$NGINX_CONF"

log "Ensuring Docker network $NETWORK_NAME exists"
docker network create "$NETWORK_NAME" >/dev/null 2>&1 || true
docker network connect "$NETWORK_NAME" "$(hostname)" >/dev/null 2>&1 || true

if [ -n "$PACKAGED_STACK_IMAGE" ] || [ -n "$PACKAGED_STACK_DIGEST" ]; then
  log "Launcher packaged DiscVault image ${PACKAGED_STACK_IMAGE:-unknown} digest ${PACKAGED_STACK_DIGEST:-unknown}"
fi

if is_digest_pinned_ref "$STACK_IMAGE"; then
  DESIRED_DIGEST="$(pinned_digest_from_ref "$STACK_IMAGE")"
  DESIRED_DIGEST_SOURCE="pinned"
  log "WARNING: $STACK_IMAGE is digest-pinned via $STACK_IMAGE_SOURCE; automatic DiscVault updates stay disabled until that override is cleared."
else
  DESIRED_DIGEST="$(remote_digest_for_ref "$STACK_IMAGE" || true)"
  if [ -z "$DESIRED_DIGEST" ]; then
    fail "Failed resolving remote digest for configured image $STACK_IMAGE"
  fi
  DESIRED_DIGEST_SOURCE="remote"
fi
STACK_IMAGE_REPO="$(image_repo_from_ref "$STACK_IMAGE")"

LAST_STACK_DIGEST="$(cat "$LAST_STACK_DIGEST_FILE" 2>/dev/null || true)"
log "DiscVault image selection source=$STACK_IMAGE_SOURCE configured_next_image=${configured_next_image_raw:-<empty>} (from $NEXT_IMAGE_SOURCE) configured_image=${configured_image_raw:-<empty>} (from $IMAGE_SOURCE) resolved_ref=$STACK_IMAGE repo=$STACK_IMAGE_REPO"
log "DiscVault desired digest source=$DESIRED_DIGEST_SOURCE desired_digest=$DESIRED_DIGEST"
log "DiscVault metadata digests packaged=${PACKAGED_STACK_DIGEST:-none} last_applied=${LAST_STACK_DIGEST:-none}"

trap 'release_rollout_lock' EXIT INT TERM
acquire_rollout_lock

for service in next-api next-worker next-mcp; do
  log_service_runtime_state "before-recreate" "$service" "$STACK_IMAGE_REPO" || true
done

STACK_IMAGE_BEFORE_ID="$(image_id "$STACK_IMAGE")"
STACK_IMAGE_BEFORE_DIGEST="$(local_digest_for_ref "$STACK_IMAGE" "$STACK_IMAGE_REPO")"
log "DiscVault local image before pull ref=$STACK_IMAGE image_id=${STACK_IMAGE_BEFORE_ID:-missing} digest=${STACK_IMAGE_BEFORE_DIGEST:-missing}"

log "Pulling DiscVault image $STACK_IMAGE"
if ! docker pull "$STACK_IMAGE"; then
  log "DiscVault image pull failed; continuing to verify local image state"
fi

STACK_IMAGE_AFTER_ID="$(image_id "$STACK_IMAGE")"
STACK_IMAGE_AFTER_DIGEST="$(local_digest_for_ref "$STACK_IMAGE" "$STACK_IMAGE_REPO")"
log "DiscVault local image after pull ref=$STACK_IMAGE image_id=${STACK_IMAGE_AFTER_ID:-missing} digest=${STACK_IMAGE_AFTER_DIGEST:-missing}"

if [ -z "$STACK_IMAGE_AFTER_DIGEST" ]; then
  fail "Resolved desired digest $DESIRED_DIGEST but local digest is unavailable after pull for $STACK_IMAGE"
fi
if [ "$STACK_IMAGE_AFTER_DIGEST" != "$DESIRED_DIGEST" ]; then
  fail "Local digest $STACK_IMAGE_AFTER_DIGEST does not match desired digest $DESIRED_DIGEST for $STACK_IMAGE"
fi

UP_ARGS="-d --remove-orphans"
# No --remove-orphans while only postgres is named, so the phase cannot be
# mistaken for "these are the only services in the project".
POSTGRES_UP_ARGS="-d"
FORCE_RECREATE_REASON=""
if [ "$ALWAYS_RECREATE_STACK" = "true" ]; then
  FORCE_RECREATE_REASON="DISCVAULT_ALWAYS_RECREATE_STACK=true"
elif [ "$FORCE_RECREATE_ON_PULL" = "true" ]; then
  if ! service_runtime_matches next-api "$DESIRED_DIGEST" "$STACK_IMAGE_AFTER_ID" "$STACK_IMAGE_REPO" || \
    ! service_runtime_matches next-worker "$DESIRED_DIGEST" "$STACK_IMAGE_AFTER_ID" "$STACK_IMAGE_REPO" || \
    ! service_runtime_matches next-mcp "$DESIRED_DIGEST" "$STACK_IMAGE_AFTER_ID" "$STACK_IMAGE_REPO"; then
    FORCE_RECREATE_REASON="Running stack service digest/image-id does not match desired digest $DESIRED_DIGEST"
  fi
fi

if [ -n "$FORCE_RECREATE_REASON" ]; then
  log "$FORCE_RECREATE_REASON; forcing stack recreate"
  UP_ARGS="-d --remove-orphans --force-recreate"
  POSTGRES_UP_ARGS="-d --force-recreate"
fi

require_secret_reaches_compose POSTGRES_PASSWORD
require_secret_reaches_compose JWT_SECRET
log "Verified stack secrets reach Compose from both $COMPOSE_ENV_FILE and the process environment"

log "Starting or updating DiscVault stack project $PROJECT_NAME"

# Postgres first, on its own. The rest of the stack depends on it being healthy,
# so a `up` naming everything blocks on next-api and fails there -- long after
# the point where a credential problem could still be reported clearly.
log "Starting PostgreSQL before the rest of the stack so credentials can be verified"
# Both variables hold space-separated argument lists, so the splitting is wanted.
# shellcheck disable=SC2086
docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up $POSTGRES_UP_ARGS postgres
verify_postgres_credentials

log "DiscVault compose services: $COMPOSE_UP_SERVICES"
# shellcheck disable=SC2086
docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up $UP_ARGS $COMPOSE_UP_SERVICES

for service in next-api next-worker next-mcp; do
  log_service_runtime_state "after-recreate" "$service" "$STACK_IMAGE_REPO" || true
done
verify_stack_after_deploy "$DESIRED_DIGEST" "$STACK_IMAGE_REPO" "$CHECK_HEALTH_SHA"

printf '%s\n' "$DESIRED_DIGEST" > "$LAST_STACK_DIGEST_FILE"
log "Recorded last applied digest $DESIRED_DIGEST in $LAST_STACK_DIGEST_FILE"

release_rollout_lock
trap - EXIT INT TERM

log "DiscVault launcher is ready"
exec nginx -g "daemon off;"
