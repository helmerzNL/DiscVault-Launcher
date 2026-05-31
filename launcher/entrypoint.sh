#!/bin/sh
set -eu

log() {
  printf '%s %s\n' "$(date -Iseconds)" "$*"
}

random_secret() {
  openssl rand -hex 32
}

image_id() {
  docker image inspect "$1" --format '{{.Id}}' 2>/dev/null || true
}

service_container_ids() {
  docker ps -aq \
    --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --filter "label=com.docker.compose.service=$1"
}

service_uses_image() {
  service="$1"
  expected_image_id="$2"
  ids="$(service_container_ids "$service")"
  if [ -z "$ids" ]; then
    return 0
  fi

  for id in $ids; do
    current_image_id="$(docker inspect "$id" --format '{{.Image}}' 2>/dev/null || true)"
    if [ -n "$current_image_id" ] && [ "$current_image_id" != "$expected_image_id" ]; then
      return 1
    fi
  done

  return 0
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

CONFIG_DIR="${DISCVAULT_LAUNCHER_CONFIG:-/config}"
ENV_FILE="$CONFIG_DIR/stack.env"
COMPOSE_FILE="$CONFIG_DIR/docker-compose.yml"
PROJECT_NAME="${DISCVAULT_PROJECT_NAME:-discvault_stack}"
NETWORK_NAME="${DISCVAULT_NETWORK:-discvault-stack}"
RP_ORIGINS_VALUE="${RP_ORIGINS:-${RP_ORIGIN:-http://localhost:${DISCVAULT_WEB_PORT:-6080}}}"
PACKAGED_STACK_IMAGE="${DISCVAULT_LAUNCHER_STACK_IMAGE:-}"
PACKAGED_STACK_DIGEST="${DISCVAULT_LAUNCHER_STACK_DIGEST:-}"
STACK_IMAGE="${DISCVAULT_IMAGE:-ghcr.io/helmerznl/discvault:beta}"
FORCE_RECREATE_ON_PULL="${DISCVAULT_FORCE_RECREATE_ON_PULL:-true}"

mkdir -p "$CONFIG_DIR"
touch "$ENV_FILE"

set_env TZ "${TZ:-Europe/Amsterdam}" "$ENV_FILE"
set_env DISCVAULT_IMAGE "$STACK_IMAGE" "$ENV_FILE"
set_env DISCVAULT_DATA_DIR_HOST "${DISCVAULT_DATA_DIR_HOST:-/mnt/user/appdata/discvault}" "$ENV_FILE"
set_env DISCVAULT_POSTGRES_DATA_DIR_HOST "${DISCVAULT_POSTGRES_DATA_DIR_HOST:-/mnt/user/appdata/discvault-postgres}" "$ENV_FILE"
set_env DISCVAULT_NETWORK "$NETWORK_NAME" "$ENV_FILE"
set_env POSTGRES_DB "${POSTGRES_DB:-discvault_next}" "$ENV_FILE"
set_env POSTGRES_USER "${POSTGRES_USER:-discvault_next}" "$ENV_FILE"
set_env RP_ID "${RP_ID:-localhost}" "$ENV_FILE"
set_env RP_NAME "${RP_NAME:-DiscVault}" "$ENV_FILE"
set_env RP_ORIGINS "$RP_ORIGINS_VALUE" "$ENV_FILE"
set_env DISCVAULT_NEXT_API_WORKERS "${DISCVAULT_NEXT_API_WORKERS:-2}" "$ENV_FILE"
set_env DISCVAULT_NEXT_API_TIMEOUT "${DISCVAULT_NEXT_API_TIMEOUT:-180}" "$ENV_FILE"
set_env DISCVAULT_WORKER_ID "${DISCVAULT_WORKER_ID:-next-worker-1}" "$ENV_FILE"
set_env DISCVAULT_WORKER_POLL_INTERVAL "${DISCVAULT_WORKER_POLL_INTERVAL:-2}" "$ENV_FILE"
set_env DISCVAULT_NEXT_ENABLE_TEST_RESET "${DISCVAULT_NEXT_ENABLE_TEST_RESET:-false}" "$ENV_FILE"

if [ -n "${POSTGRES_PASSWORD:-}" ]; then
  set_env POSTGRES_PASSWORD "$POSTGRES_PASSWORD" "$ENV_FILE"
else
  ensure_env POSTGRES_PASSWORD "$(random_secret)" "$ENV_FILE"
fi

if [ -n "${JWT_SECRET:-}" ]; then
  set_env JWT_SECRET "$JWT_SECRET" "$ENV_FILE"
else
  ensure_env JWT_SECRET "$(random_secret)" "$ENV_FILE"
fi

cp /opt/discvault-launcher/docker-compose.yml "$COMPOSE_FILE"

log "Ensuring Docker network $NETWORK_NAME exists"
docker network create "$NETWORK_NAME" >/dev/null 2>&1 || true
docker network connect "$NETWORK_NAME" "$(hostname)" >/dev/null 2>&1 || true

if [ -n "$PACKAGED_STACK_IMAGE" ] || [ -n "$PACKAGED_STACK_DIGEST" ]; then
  log "Launcher packaged stack image ${PACKAGED_STACK_IMAGE:-unknown} digest ${PACKAGED_STACK_DIGEST:-unknown}"
fi

STACK_IMAGE_BEFORE="$(image_id "$STACK_IMAGE")"
log "Managed DiscVault stack image $STACK_IMAGE local image ${STACK_IMAGE_BEFORE:-missing before pull}"

log "Pulling DiscVault stack images"
if ! docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" pull; then
  log "Image pull failed; continuing with locally available images"
fi

STACK_IMAGE_AFTER="$(image_id "$STACK_IMAGE")"
log "Managed DiscVault stack image $STACK_IMAGE local image ${STACK_IMAGE_AFTER:-missing after pull}"
UP_ARGS="-d --remove-orphans"
FORCE_RECREATE_REASON=""
if [ "$FORCE_RECREATE_ON_PULL" = "true" ] && [ -n "$STACK_IMAGE_BEFORE" ] && [ -n "$STACK_IMAGE_AFTER" ] && [ "$STACK_IMAGE_BEFORE" != "$STACK_IMAGE_AFTER" ]; then
  FORCE_RECREATE_REASON="DiscVault image changed from $STACK_IMAGE_BEFORE to $STACK_IMAGE_AFTER"
elif [ "$FORCE_RECREATE_ON_PULL" = "true" ] && [ -n "$STACK_IMAGE_AFTER" ]; then
  if ! service_uses_image next-api "$STACK_IMAGE_AFTER" || ! service_uses_image next-worker "$STACK_IMAGE_AFTER"; then
    FORCE_RECREATE_REASON="Running DiscVault containers are not using local $STACK_IMAGE image $STACK_IMAGE_AFTER"
  fi
fi

if [ -n "$FORCE_RECREATE_REASON" ]; then
  log "$FORCE_RECREATE_REASON; forcing stack recreate"
  UP_ARGS="-d --remove-orphans --force-recreate"
fi

log "Starting or updating DiscVault stack project $PROJECT_NAME"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up $UP_ARGS

log "DiscVault launcher is ready"
exec nginx -g "daemon off;"
