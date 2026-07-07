#!/bin/sh
set -eu

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

remote_digest_for_ref() {
  digest="$(docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
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

require_non_empty_env() {
  key="$1"
  file="$2"
  current="$(env_file_value "$key" "$file")"
  if [ -z "$current" ]; then
    fail "Required launcher env $key is empty in $file"
  fi
}

export_env_from_file() {
  key="$1"
  file="$2"
  value="$(env_file_value "$key" "$file")"
  export "$key=$value"
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

configured_next_image="${DISCVAULT_NEXT_IMAGE:-$(env_file_value DISCVAULT_NEXT_IMAGE "$ENV_FILE")}"
configured_image="${DISCVAULT_IMAGE:-$(env_file_value DISCVAULT_IMAGE "$ENV_FILE")}"

if [ -n "$configured_next_image" ] && [ "$configured_next_image" != "auto" ]; then
  STACK_IMAGE="$configured_next_image"
  STACK_IMAGE_SOURCE="DISCVAULT_NEXT_IMAGE"
elif [ -n "$configured_image" ] && [ "$configured_image" != "auto" ]; then
  STACK_IMAGE="$configured_image"
  STACK_IMAGE_SOURCE="DISCVAULT_IMAGE"
else
  STACK_IMAGE="${PACKAGED_STACK_IMAGE:-ghcr.io/helmerznl/discvault:v26-beta}"
  STACK_IMAGE_SOURCE="packaged-default"
fi

if [ -z "$STACK_IMAGE" ]; then
  fail "No DiscVault image reference could be resolved"
fi

export DISCVAULT_IMAGE="$STACK_IMAGE"
if [ -n "$configured_next_image" ]; then
  export DISCVAULT_NEXT_IMAGE="$configured_next_image"
fi

DEPLOYMENT_MODE="${DISCVAULT_DEPLOYMENT_MODE:-auto}"
if [ "$DEPLOYMENT_MODE" = "auto" ]; then
  case "$STACK_IMAGE" in
    *:latest|*:legacy)
      DEPLOYMENT_MODE="legacy"
      ;;
    *)
      DEPLOYMENT_MODE="stack"
      ;;
  esac
fi
if [ "$DEPLOYMENT_MODE" != "legacy" ] && [ "$DEPLOYMENT_MODE" != "stack" ]; then
  fail "Unsupported DISCVAULT_DEPLOYMENT_MODE=$DEPLOYMENT_MODE; use auto, legacy, or stack"
fi

set_env TZ "${TZ:-Europe/Amsterdam}" "$ENV_FILE"
set_env DISCVAULT_IMAGE "$STACK_IMAGE" "$ENV_FILE"
set_env DISCVAULT_NEXT_IMAGE "$configured_next_image" "$ENV_FILE"
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
  RP_ID \
  RP_NAME \
  RP_ORIGIN \
  RP_ORIGINS \
  DISCVAULT_NEXT_MCP_PORT \
  DISCVAULT_NEXT_API_WORKERS \
  DISCVAULT_NEXT_API_TIMEOUT \
  DISCVAULT_WORKER_ID \
  DISCVAULT_WORKER_POLL_INTERVAL \
  DISCVAULT_NEXT_ENABLE_TEST_RESET
do
  export_env_from_file "$key" "$ENV_FILE"
done
log "Exported launcher env file values for Docker Compose"
log_env_snapshot \
  DISCVAULT_NEXT_IMAGE \
  DISCVAULT_IMAGE \
  DISCVAULT_DEPLOYMENT_MODE \
  DISCVAULT_FORCE_RECREATE_ON_PULL \
  DISCVAULT_ALWAYS_RECREATE_STACK \
  DISCVAULT_CHECK_HEALTH_SHA \
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
  POSTGRES_DB \
  POSTGRES_USER \
  POSTGRES_PASSWORD \
  JWT_SECRET

if [ "$DEPLOYMENT_MODE" = "legacy" ]; then
  cp /opt/discvault-launcher/docker-compose.legacy.yml "$COMPOSE_FILE"
  DISCVAULT_UPSTREAM="next-api:80"
  DISCVAULT_MCP_LOCATIONS=""
  COMPOSE_UP_SERVICES="next-api"
else
  DISCVAULT_UPSTREAM="next-api:5000"
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
  }' /opt/discvault-launcher/docker-compose.yml > "$COMPOSE_FILE"
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
fi
awk -v upstream="$DISCVAULT_UPSTREAM" -v mcp_locations="$DISCVAULT_MCP_LOCATIONS" '{
  gsub(/__DISCVAULT_UPSTREAM__/, upstream)
  if ($0 ~ /__DISCVAULT_MCP_LOCATIONS__/) {
    print mcp_locations
  } else {
    print
  }
}' /opt/discvault-launcher/nginx.conf.template > /etc/nginx/http.d/default.conf

log "Ensuring Docker network $NETWORK_NAME exists"
docker network create "$NETWORK_NAME" >/dev/null 2>&1 || true
docker network connect "$NETWORK_NAME" "$(hostname)" >/dev/null 2>&1 || true

if [ -n "$PACKAGED_STACK_IMAGE" ] || [ -n "$PACKAGED_STACK_DIGEST" ]; then
  log "Launcher packaged DiscVault image ${PACKAGED_STACK_IMAGE:-unknown} digest ${PACKAGED_STACK_DIGEST:-unknown}"
fi

if is_digest_pinned_ref "$STACK_IMAGE"; then
  DESIRED_DIGEST="$(pinned_digest_from_ref "$STACK_IMAGE")"
  DESIRED_DIGEST_SOURCE="pinned"
else
  DESIRED_DIGEST="$(remote_digest_for_ref "$STACK_IMAGE" || true)"
  if [ -z "$DESIRED_DIGEST" ]; then
    fail "Failed resolving remote digest for configured image $STACK_IMAGE"
  fi
  DESIRED_DIGEST_SOURCE="remote"
fi
STACK_IMAGE_REPO="$(image_repo_from_ref "$STACK_IMAGE")"

LAST_STACK_DIGEST="$(cat "$LAST_STACK_DIGEST_FILE" 2>/dev/null || true)"
log "DiscVault image selection source=$STACK_IMAGE_SOURCE configured_ref=$STACK_IMAGE repo=$STACK_IMAGE_REPO deployment_mode=$DEPLOYMENT_MODE"
log "DiscVault desired digest source=$DESIRED_DIGEST_SOURCE desired_digest=$DESIRED_DIGEST"
log "DiscVault metadata digests packaged=${PACKAGED_STACK_DIGEST:-none} last_applied=${LAST_STACK_DIGEST:-none}"

trap 'release_rollout_lock' EXIT INT TERM
acquire_rollout_lock

if [ "$DEPLOYMENT_MODE" = "legacy" ]; then
  log_service_runtime_state "before-recreate" next-api "$STACK_IMAGE_REPO" || true
else
  log_service_runtime_state "before-recreate" next-api "$STACK_IMAGE_REPO" || true
  log_service_runtime_state "before-recreate" next-worker "$STACK_IMAGE_REPO" || true
  log_service_runtime_state "before-recreate" next-mcp "$STACK_IMAGE_REPO" || true
fi

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
FORCE_RECREATE_REASON=""
if [ "$ALWAYS_RECREATE_STACK" = "true" ]; then
  FORCE_RECREATE_REASON="DISCVAULT_ALWAYS_RECREATE_STACK=true"
elif [ "$FORCE_RECREATE_ON_PULL" = "true" ]; then
  if [ "$DEPLOYMENT_MODE" = "legacy" ]; then
    if ! service_runtime_matches next-api "$DESIRED_DIGEST" "$STACK_IMAGE_AFTER_ID" "$STACK_IMAGE_REPO"; then
      FORCE_RECREATE_REASON="Running legacy service digest/image-id does not match desired digest $DESIRED_DIGEST"
    fi
  else
    if ! service_runtime_matches next-api "$DESIRED_DIGEST" "$STACK_IMAGE_AFTER_ID" "$STACK_IMAGE_REPO" || \
      ! service_runtime_matches next-worker "$DESIRED_DIGEST" "$STACK_IMAGE_AFTER_ID" "$STACK_IMAGE_REPO" || \
      ! service_runtime_matches next-mcp "$DESIRED_DIGEST" "$STACK_IMAGE_AFTER_ID" "$STACK_IMAGE_REPO"; then
      FORCE_RECREATE_REASON="Running stack service digest/image-id does not match desired digest $DESIRED_DIGEST"
    fi
  fi
fi

if [ -n "$FORCE_RECREATE_REASON" ]; then
  log "$FORCE_RECREATE_REASON; forcing stack recreate"
  UP_ARGS="-d --remove-orphans --force-recreate"
fi

log "Starting or updating DiscVault $DEPLOYMENT_MODE project $PROJECT_NAME"
log "DiscVault compose services: $COMPOSE_UP_SERVICES"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up $UP_ARGS $COMPOSE_UP_SERVICES

if [ "$DEPLOYMENT_MODE" = "legacy" ]; then
  log_service_runtime_state "after-recreate" next-api "$STACK_IMAGE_REPO" || true
else
  log_service_runtime_state "after-recreate" next-api "$STACK_IMAGE_REPO" || true
  log_service_runtime_state "after-recreate" next-worker "$STACK_IMAGE_REPO" || true
  log_service_runtime_state "after-recreate" next-mcp "$STACK_IMAGE_REPO" || true
  verify_stack_after_deploy "$DESIRED_DIGEST" "$STACK_IMAGE_REPO" "$CHECK_HEALTH_SHA"
fi

printf '%s\n' "$DESIRED_DIGEST" > "$LAST_STACK_DIGEST_FILE"
log "Recorded last applied digest $DESIRED_DIGEST in $LAST_STACK_DIGEST_FILE"

release_rollout_lock
trap - EXIT INT TERM

log "DiscVault launcher is ready"
exec nginx -g "daemon off;"
