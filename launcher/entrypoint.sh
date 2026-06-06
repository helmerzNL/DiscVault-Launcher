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
    return 1
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
    log "Required launcher env $key is empty in $file"
    exit 1
  fi
}

export_env_from_file() {
  key="$1"
  file="$2"
  value="$(env_file_value "$key" "$file")"
  export "$key=$value"
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
if [ -z "${DISCVAULT_IMAGE:-}" ] || [ "${DISCVAULT_IMAGE:-}" = "auto" ]; then
  STACK_IMAGE="${PACKAGED_STACK_IMAGE:-ghcr.io/helmerznl/discvault:v26-beta}"
else
  STACK_IMAGE="$DISCVAULT_IMAGE"
fi
export DISCVAULT_IMAGE="$STACK_IMAGE"
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
  log "Unsupported DISCVAULT_DEPLOYMENT_MODE=$DEPLOYMENT_MODE; use auto, legacy, or stack"
  exit 1
fi
FORCE_RECREATE_ON_PULL="${DISCVAULT_FORCE_RECREATE_ON_PULL:-true}"
ALWAYS_RECREATE_STACK="${DISCVAULT_ALWAYS_RECREATE_STACK:-false}"

mkdir -p "$CONFIG_DIR"
touch "$ENV_FILE"
log "Using launcher config directory $CONFIG_DIR"
log "Using launcher env file $ENV_FILE"

set_env TZ "${TZ:-Europe/Amsterdam}" "$ENV_FILE"
set_env DISCVAULT_IMAGE "$STACK_IMAGE" "$ENV_FILE"
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

STACK_IMAGE_BEFORE="$(image_id "$STACK_IMAGE")"
log "Managed DiscVault image $STACK_IMAGE local image ${STACK_IMAGE_BEFORE:-missing before pull}"

log "Pulling DiscVault image $STACK_IMAGE"
if ! docker pull "$STACK_IMAGE"; then
  log "DiscVault image pull failed; continuing with locally available image"
fi

STACK_IMAGE_AFTER="$(image_id "$STACK_IMAGE")"
log "Managed DiscVault image $STACK_IMAGE local image ${STACK_IMAGE_AFTER:-missing after pull}"
UP_ARGS="-d --remove-orphans"
FORCE_RECREATE_REASON=""
LAST_STACK_DIGEST="$(cat "$LAST_STACK_DIGEST_FILE" 2>/dev/null || true)"
log "DiscVault deployment mode $DEPLOYMENT_MODE using upstream $DISCVAULT_UPSTREAM"
log "Last applied DiscVault image digest ${LAST_STACK_DIGEST:-none}"
if [ "$ALWAYS_RECREATE_STACK" = "true" ]; then
  FORCE_RECREATE_REASON="DISCVAULT_ALWAYS_RECREATE_STACK=true"
elif [ "$FORCE_RECREATE_ON_PULL" = "true" ] && [ -n "$PACKAGED_STACK_DIGEST" ] && [ "$PACKAGED_STACK_DIGEST" != "unknown" ] && [ "$PACKAGED_STACK_DIGEST" != "$LAST_STACK_DIGEST" ]; then
  FORCE_RECREATE_REASON="Packaged DiscVault image digest changed from ${LAST_STACK_DIGEST:-none} to $PACKAGED_STACK_DIGEST"
elif [ "$FORCE_RECREATE_ON_PULL" = "true" ] && [ -n "$STACK_IMAGE_BEFORE" ] && [ -n "$STACK_IMAGE_AFTER" ] && [ "$STACK_IMAGE_BEFORE" != "$STACK_IMAGE_AFTER" ]; then
  FORCE_RECREATE_REASON="DiscVault image changed from $STACK_IMAGE_BEFORE to $STACK_IMAGE_AFTER"
elif [ "$FORCE_RECREATE_ON_PULL" = "true" ] && [ -n "$STACK_IMAGE_AFTER" ]; then
  if [ "$DEPLOYMENT_MODE" = "legacy" ]; then
    if ! service_uses_image next-api "$STACK_IMAGE_AFTER"; then
      FORCE_RECREATE_REASON="Running DiscVault legacy container is not using local $STACK_IMAGE image $STACK_IMAGE_AFTER"
    fi
  elif ! service_uses_image next-api "$STACK_IMAGE_AFTER" || ! service_uses_image next-worker "$STACK_IMAGE_AFTER" || ! service_uses_image next-mcp "$STACK_IMAGE_AFTER"; then
    FORCE_RECREATE_REASON="Running DiscVault containers are not using local $STACK_IMAGE image $STACK_IMAGE_AFTER"
  fi
fi

if [ -n "$FORCE_RECREATE_REASON" ]; then
  log "$FORCE_RECREATE_REASON; forcing stack recreate"
  UP_ARGS="-d --remove-orphans --force-recreate"
fi

log "Starting or updating DiscVault $DEPLOYMENT_MODE project $PROJECT_NAME"
log "DiscVault compose services: $COMPOSE_UP_SERVICES"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up $UP_ARGS $COMPOSE_UP_SERVICES
if [ -n "$PACKAGED_STACK_DIGEST" ] && [ "$PACKAGED_STACK_DIGEST" != "unknown" ]; then
  printf '%s\n' "$PACKAGED_STACK_DIGEST" > "$LAST_STACK_DIGEST_FILE"
fi

log "DiscVault launcher is ready"
exec nginx -g "daemon off;"
