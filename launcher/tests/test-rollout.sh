#!/bin/sh
#
# End-to-end rollout tests for launcher/entrypoint.sh against a scripted docker
# stub. These cover the parts that only show up when the whole script runs:
# ordering of the compose calls, what reaches the compose env file, and how
# failures are reported.
#
# The case that prompted them: postgres reported healthy while the credentials
# it was initialised with did not match the ones the launcher hands out.
# pg_isready does not authenticate, so the real error surfaced three layers away
# as a next-api restart loop and a generic "dependency failed to start".
#
# Run with: sh launcher/tests/test-rollout.sh

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"

FAILURES=0
CHECKS=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

BIN="$WORK/bin"
mkdir -p "$BIN"
cp "$SCRIPT_DIR/fixtures/docker" "$BIN/docker"
chmod +x "$BIN/docker"
# The entrypoint execs nginx last and curls next-api's health endpoint.
# Heredocs rather than printf: \xHH is a bash extension and this suite also runs
# under dash and busybox ash, where it would be emitted literally.
cat > "$BIN/nginx" <<'STUB'
#!/bin/sh
echo NGINX-STARTED
STUB
cat > "$BIN/curl" <<'STUB'
#!/bin/sh
echo '{"sha":"stubrevision"}'
STUB
chmod +x "$BIN/nginx" "$BIN/curl"

# Run the entrypoint in an isolated config dir. Extra environment comes from the
# caller as KEY=VALUE arguments.
run_entrypoint() {
  name="$1"
  shift
  cfg="$WORK/$name"
  rm -rf "$cfg"
  mkdir -p "$cfg"
  RUN_CFG="$cfg"
  RUN_LOG="$cfg/out.log"
  RUN_STUB_LOG="$cfg/docker-calls.log"
  : > "$RUN_STUB_LOG"

  set +e
  env PATH="$BIN:$PATH" \
    STUB_LOG="$RUN_STUB_LOG" \
    DISCVAULT_LAUNCHER_LIB="$ROOT/launcher/lib.sh" \
    DISCVAULT_LAUNCHER_CONFIG="$cfg" \
    DISCVAULT_LAUNCHER_COMPOSE_TEMPLATE="$ROOT/stack/docker-compose.launcher.yml" \
    DISCVAULT_LAUNCHER_NGINX_TEMPLATE="$ROOT/launcher/nginx.conf" \
    DISCVAULT_LAUNCHER_NGINX_CONF="$cfg/nginx.conf" \
    DISCVAULT_LAUNCHER_STACK_IMAGE=ghcr.io/helmerznl/discvault:beta \
    DISCVAULT_IMAGE=auto \
    DISCVAULT_NEXT_IMAGE= \
    DISCVAULT_POSTGRES_PROBE_ATTEMPTS=2 \
    DISCVAULT_POSTGRES_PROBE_INTERVAL=0 \
    "$@" \
    sh "$ROOT/launcher/entrypoint.sh" > "$RUN_LOG" 2>&1
  RUN_STATUS=$?
  set -e
}

expect_status() {
  label="$1"; expected="$2"
  CHECKS=$((CHECKS + 1))
  if [ "$RUN_STATUS" = "$expected" ]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s (exit %s, expected %s)\n' "$label" "$RUN_STATUS" "$expected"
    sed -n '$p' "$RUN_LOG" | sed 's/^/       last line: /'
    FAILURES=$((FAILURES + 1))
  fi
}

expect_log() {
  label="$1"; pattern="$2"
  CHECKS=$((CHECKS + 1))
  if grep -q "$pattern" "$RUN_LOG"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s (no match for %s)\n' "$label" "$pattern"
    FAILURES=$((FAILURES + 1))
  fi
}

expect_no_log() {
  label="$1"; pattern="$2"
  CHECKS=$((CHECKS + 1))
  if grep -q "$pattern" "$RUN_LOG"; then
    printf 'FAIL %s (unexpected match for %s)\n' "$label" "$pattern"
    FAILURES=$((FAILURES + 1))
  else
    printf 'ok   %s\n' "$label"
  fi
}

expect_stub() {
  label="$1"; pattern="$2"
  CHECKS=$((CHECKS + 1))
  if grep -q "$pattern" "$RUN_STUB_LOG"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s (docker was never called matching %s)\n' "$label" "$pattern"
    FAILURES=$((FAILURES + 1))
  fi
}

expect_no_stub() {
  label="$1"; pattern="$2"
  CHECKS=$((CHECKS + 1))
  if grep -q "$pattern" "$RUN_STUB_LOG"; then
    printf 'FAIL %s (docker was called matching %s)\n' "$label" "$pattern"
    FAILURES=$((FAILURES + 1))
  else
    printf 'ok   %s\n' "$label"
  fi
}

echo '# healthy rollout'

run_entrypoint healthy STUB_PSQL=ok
expect_status 'completes successfully' 0
expect_log 'starts nginx' 'NGINX-STARTED'
expect_log 'verifies the database credentials' 'PostgreSQL accepted the configured credentials'
expect_stub 'brings postgres up on its own first' 'compose .* up .* postgres$'
expect_stub 'then brings the full stack up' 'compose .* up .*next-api next-worker next-mcp'
expect_stub 'probes with an authenticated psql' 'exec .*psql'

echo '# credentials rejected by an existing data directory'

run_entrypoint authfail STUB_PSQL=auth-failed
expect_status 'refuses to continue' 1
expect_log 'names the cause' 'password authentication'
expect_log 'explains that POSTGRES_PASSWORD only applies at initialisation' 'only applies when the data directory is first initialised'
expect_log 'points at the data directory' 'DISCVAULT_POSTGRES_DATA_DIR_HOST'
expect_log 'offers the opt-in resync' 'DISCVAULT_POSTGRES_SYNC_PASSWORD'
expect_no_log 'does not start nginx' 'NGINX-STARTED'
expect_no_stub 'never starts the rest of the stack' 'compose .* up .*next-api next-worker next-mcp'

echo '# opt-in password reconciliation'

run_entrypoint sync STUB_PSQL=auth-failed STUB_ALTER_USER=ok \
  DISCVAULT_POSTGRES_SYNC_PASSWORD=true
# The statement travels over stdin, so the stub records only its kind -- argv
# must not carry the new password.
expect_stub 'runs ALTER USER' '^exec-sql: ALTER USER$'
expect_log 'logs the reconciliation' 'Resynchronised the PostgreSQL password'
expect_log 'continues the rollout' 'DiscVault launcher is ready'
expect_status 'completes successfully' 0

run_entrypoint syncfail STUB_PSQL=auth-failed STUB_ALTER_USER=fail \
  DISCVAULT_POSTGRES_SYNC_PASSWORD=true
expect_status 'still fails when the resync itself fails' 1
expect_log 'reports the failed resync' 'Could not resynchronise'

echo '# postgres unreachable is reported differently'

# "Server refused the password" and "server is not answering" need different
# advice; conflating them sends people to edit a password that was never wrong.
run_entrypoint unreachable STUB_PSQL=unreachable
expect_status 'refuses to continue' 1
expect_log 'reports it as unreachable' 'did not accept connections'
expect_no_log 'does not blame the password' 'only applies when the data directory is first initialised'

echo '# secrets never reach the logs'

run_entrypoint secrets STUB_PSQL=ok POSTGRES_PASSWORD=hunter2-not-in-logs JWT_SECRET=jwt-not-in-logs
CHECKS=$((CHECKS + 1))
leaked="$(grep -l -e 'hunter2-not-in-logs' -e 'jwt-not-in-logs' "$RUN_CFG/out.log" "$RUN_CFG"/logs/*.log "$RUN_STUB_LOG" 2>/dev/null || true)"
if [ -z "$leaked" ]; then
  printf 'ok   %s\n' 'no secret appears in the launcher output, boot logs or docker argv'
else
  printf 'FAIL secrets leaked into: %s\n' "$leaked"
  FAILURES=$((FAILURES + 1))
fi

printf '\n%s checks, %s failures\n' "$CHECKS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
