FROM docker:27-cli

ARG DISCVAULT_STACK_IMAGE=ghcr.io/helmerznl/discvault:v26-beta
ARG DISCVAULT_STACK_DIGEST=unknown

RUN apk add --no-cache ca-certificates curl docker-cli-compose nginx openssl \
    && mkdir -p /run/nginx /var/lib/nginx/tmp/client_body /opt/discvault-launcher

COPY launcher/entrypoint.sh /usr/local/bin/discvault-launcher
COPY launcher/nginx.conf /opt/discvault-launcher/nginx.conf.template
COPY stack/docker-compose.launcher.yml /opt/discvault-launcher/docker-compose.yml
COPY stack/docker-compose.legacy.yml /opt/discvault-launcher/docker-compose.legacy.yml

RUN chmod +x /usr/local/bin/discvault-launcher

ENV DISCVAULT_LAUNCHER_CONFIG=/config \
    DISCVAULT_PROJECT_NAME=discvault_stack \
    DISCVAULT_NETWORK=discvault-stack \
    DISCVAULT_IMAGE=auto \
    DISCVAULT_DATA_DIR_HOST=/mnt/user/appdata/discvault \
    DISCVAULT_POSTGRES_DATA_DIR_HOST=/mnt/user/appdata/discvault-postgres \
    DISCVAULT_WEB_PORT=6080 \
    DISCVAULT_NEXT_API_WORKERS=2 \
    DISCVAULT_NEXT_API_TIMEOUT=180 \
    DISCVAULT_WORKER_ID=next-worker-1 \
    DISCVAULT_WORKER_POLL_INTERVAL=2 \
    DISCVAULT_NEXT_ENABLE_TEST_RESET=false \
    DISCVAULT_FORCE_RECREATE_ON_PULL=true \
    DISCVAULT_ALWAYS_RECREATE_STACK=false \
    POSTGRES_DB=discvault_next \
    POSTGRES_USER=discvault_next \
    RP_ID=localhost \
    RP_NAME=DiscVault \
    TZ=Europe/Amsterdam \
    DISCVAULT_LAUNCHER_STACK_IMAGE=${DISCVAULT_STACK_IMAGE} \
    DISCVAULT_LAUNCHER_STACK_DIGEST=${DISCVAULT_STACK_DIGEST}

LABEL eu.discvault.stack.image="${DISCVAULT_STACK_IMAGE}" \
      eu.discvault.stack.digest="${DISCVAULT_STACK_DIGEST}"

VOLUME ["/config"]
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=5 \
  CMD curl -fsS http://127.0.0.1/launcher-health >/dev/null || exit 1

CMD ["discvault-launcher"]
