# DiscVault Launcher

DiscVault Launcher is a small deployment manager for DiscVault Docker channels.
It runs the PostgreSQL-backed DiscVault 26 stack. It is intentionally separate
from the DiscVault application image and from the standalone Docker Compose
stack.

The split is deliberate:

- `helmerznl/discvault` is the DiscVault app image.
- `helmerznl/discvault-launcher` is the optional management/proxy image.
- `stack/docker-compose.yml` can be used directly without the launcher.
- `unraid/discvault.xml` lets Unraid Community Apps install one container that
  manages the full DiscVault stack behind the scenes.

## Architecture

```text
Unraid Community Apps
  -> DiscVault Launcher container
    -> Docker socket
      -> v26 stack: postgres + next-api + next-worker + next-mcp
    -> Nginx proxy on the Unraid WebUI port
```

The launcher keeps running as the public web endpoint and proxies `/` to
`next-api:5000` and `/mcp` to `next-mcp:6090`. The managed containers do not
bind their own host ports in launcher mode, so an existing Unraid WebUI port
such as `6080` stays stable.

### Legacy mode was removed

DiscVault deleted `app/Dockerfile` and now builds every channel — including
`:latest` — from `app/Dockerfile.v26`. Every published `helmerznl/discvault`
image is therefore the v26 stack, and the launcher no longer has a legacy
single-container mode. `DISCVAULT_DEPLOYMENT_MODE=legacy` is still accepted but
logs a warning and runs the v26 stack.

The `helmerznl/discvault-launcher:legacy` tag is no longer published as a
result. If you are still on it, switch the Unraid repository to
`ghcr.io/helmerznl/discvault-launcher:latest`; the frozen `discvault:legacy` app
image can no longer be deployed by the launcher.

## Standalone Docker Compose

Use this when you do not need the launcher:

```bash
cd stack
cp .env.example .env
# Edit POSTGRES_PASSWORD, JWT_SECRET, RP_ID and RP_ORIGINS.
docker compose up -d
```

Open `http://localhost:6180` by default.

For an existing DiscVault beta data directory, set:

```env
DISCVAULT_DATA_DIR=/mnt/user/appdata/discvault
```

DiscVault Next reads `/data/discvault.db` and existing media folders through the
migration UI.

## Launcher Docker Run

Use this when you want the launcher to create and update the stack:

```bash
docker run -d \
  --name discvault-launcher \
  -p 6080:80 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /mnt/user/appdata/discvault-launcher:/config \
  -e DISCVAULT_DATA_DIR_HOST=/mnt/user/appdata/discvault \
  -e DISCVAULT_POSTGRES_DATA_DIR_HOST=/mnt/user/appdata/discvault-postgres \
  -e RP_ID=localhost \
  -e RP_ORIGINS=http://localhost:6080 \
  ghcr.io/helmerznl/discvault-launcher:v26-beta
```

The first start writes generated secrets to `/config/stack.env`. Keep that file
stable; it contains the PostgreSQL password and JWT secret used by the stack.

`stack.env` is **not** authoritative for image selection. `DISCVAULT_NEXT_IMAGE`
and `DISCVAULT_IMAGE` are always read from the container environment, so
clearing the field in Unraid really clears the override. Any stale value left in
`stack.env` is ignored and logged.

## Unraid Community Apps

Publish `unraid/discvault.xml` to the Unraid template repository. The template
name is `DiscVault` on purpose, so it can become the Community Apps path for
existing DiscVault beta users.

Recommended appdata paths:

```text
/mnt/user/appdata/discvault           existing beta data and SQLite database
/mnt/user/appdata/discvault-postgres  PostgreSQL data
/mnt/user/appdata/discvault-launcher  launcher config and generated secrets
```

After installation, open the WebUI and follow `/api/next/migration` when the app
reports that legacy migration is required.

## Stack Configuration

The launcher persists the stack settings in `/config/stack.env` and maps them
into the managed containers. The contract it has to satisfy is DiscVault's own
reference deployment, `app/deploy/next/.env.example` and the matching
`app/deploy/next/docker-compose.yml`; `launcher/tests/test-env-coverage.sh`
fails when a variable exists there but the launcher does not plumb it through.

Optional settings beyond the defaults:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DISCVAULT_NEXT_KEY_ENCRYPTION_KEY` | empty | Separate stable key for MovieVault credentials encrypted in PostgreSQL. Empty derives them from `JWT_SECRET`. |
| `LEGACY_AUTH_ENABLED` | `false` | Opt-in password + TOTP login. Passkeys remain the recommended method. |
| `DISCVAULT_ADMIN_DEDUP_EXECUTE_ENABLED` | `false` | Enables destructive admin dedup execution. |

`DISCVAULT_NEXT_KEY_ENCRYPTION_KEY` is deliberately **not** auto-generated. The
app falls back to `JWT_SECRET` when it is empty, so minting a separate key would
make credentials that an existing install already encrypted under `JWT_SECRET`
unreadable. Set it before first use, or re-enter the MovieVault credentials
after setting it.

`JWT_SECRET` and `DISCVAULT_NEXT_KEY_ENCRYPTION_KEY` go to both `next-api` and
`next-worker`. The worker validates the same runtime secrets as the API on
startup, and an encryption key that differs between the two makes credentials
written by one process unreadable by the other.

`BUILD_VERSION` is intentionally not mapped into `next-api`. The image bakes the
exact build version; overriding it with the launcher's coarse channel name would
make the app report a less precise version than it already knows.

## Update Model

Unraid can only check the container image that Community Apps installed. It
cannot see updates for the child Compose containers that the launcher manages.
For that reason the launcher repository contains `Stack Image Update Watch`.
That workflow checks the DiscVault channel digest and republishes the launcher
tag when the stack image changes.

1. `Stack Image Update Watch` sees a new `helmerznl/discvault` digest and
   republishes the matching launcher channel.
2. Unraid detects the launcher image update.
3. Community Apps or the Auto Update plugin updates the launcher container.
4. The launcher starts and pulls only the resolved DiscVault app image.
5. Every channel runs the PostgreSQL-backed v26 stack.
6. `next-api` applies PostgreSQL migrations before serving traffic.
7. The existing beta data stays in place and is imported by the migration UI.

The launcher only checks for a new DiscVault image **at container start**. It
does not poll while running, so a new DiscVault build reaches you when the
launcher container restarts — either through the Unraid update above, or by
restarting the container by hand.

The launcher resolves image rollouts in this order:

1. `DISCVAULT_NEXT_IMAGE` (primary override for v26 stack deployments).
2. `DISCVAULT_IMAGE` (fallback, including `auto` behavior).
3. Launcher-packaged default image for the current channel.

Both variables are read from the container environment only. An empty value
means "no override"; a value stored in `/config/stack.env` is never used unless
the variable is absent from the environment entirely.

If no override is set, the safe default is `ghcr.io/helmerznl/discvault:latest`.
Manual GitHub Actions launcher publishes should therefore default to baking in
`discvault:latest` unless a different DiscVault image is intentionally selected.

Shorthand resolution:

- Anything containing a `/` is used as-is (a full image reference, with an
  optional `:tag` and/or `@sha256:` digest).
- `auto` and `prod` map to `ghcr.io/helmerznl/discvault:latest`. They are not
  real tags; they mean "the stable channel".
- Any other bare value is the tag of the same name on
  `ghcr.io/helmerznl/discvault`. That covers `latest`, `stable`, `v26`,
  `v26-beta`, `beta`, `dev`, and immutable release tags such as `v26.7.7`.

For mutable tags such as `v26-beta`, the launcher resolves the current remote
digest and treats that digest as the deployment source-of-truth. For digest
pinned refs (`repo@sha256:...` or `repo:tag@sha256:...`), it uses the pinned
digest exactly.

Rollout decisions compare desired digest versus local digest and running
container digest/image-id (`next-api`, `next-worker`, `next-mcp`). Any mismatch
forces pull + recreate for the relevant services. `packaged` and
`/config/last-stack-digest` values are retained for metadata/logging only and
never block newer remote digests.

After recreate, the launcher verifies runtime digest, image label
`org.opencontainers.image.revision`, and (by default) `/api/next/health.sha`.
Any mismatch exits with a non-zero error instead of reporting a vague
"up-to-date" state.

For troubleshooting or aggressive test deployments, set
`DISCVAULT_ALWAYS_RECREATE_STACK=true`. That forces `--force-recreate` on every
launcher start after pulling.

### Explicit pinning

To force a deterministic build, set the `DISCVAULT_NEXT_IMAGE` container
variable (the Unraid field, or `-e` on `docker run`) to a digest-pinned
reference:

```env
DISCVAULT_NEXT_IMAGE=ghcr.io/helmerznl/discvault:v26-beta@sha256:<digest>
```

Then restart the launcher container. A pinned digest disables automatic updates
by design; the launcher logs a warning on every boot while a pin is active.
Clear the variable to resume normal channel updates.

Do not pin by editing `/config/stack.env` — that file is no longer read for
image selection, precisely so a forgotten pin cannot freeze the stack.

### Launcher boot-session logs

Each launcher startup writes a timestamped boot-session logfile to:

```text
/config/logs/launcher-boot-<UTC timestamp>-<pid>.log
```

The same lines are also emitted to stdout for easy Unraid log viewing. Logs
always include timestamps and rollout digest/sha decisions. Environment
snapshots are logged too, but secret values (passwords/secrets/tokens/keys) are
always redacted. Default retention is the latest 50 boot sessions
(`DISCVAULT_BOOT_LOG_RETENTION=50`).

Manual testing with the current Next channel can republish the beta launcher
when the development stack image changes. Use this while the Unraid template is
still installed as `discvault-launcher:v26-beta` but `DISCVAULT_NEXT_IMAGE`
points to `ghcr.io/helmerznl/discvault:dev`:

```bash
gh workflow run "Stack Image Update Watch" \
  -f stack_image=ghcr.io/helmerznl/discvault:dev \
  -f launcher_tag=v26-beta \
  -f force=true
```

For predictable development updates, use matching development tags in Unraid:

```text
Repository:      ghcr.io/helmerznl/discvault-launcher:dev
DISCVAULT_NEXT_IMAGE: auto
DISCVAULT_IMAGE: auto
```

The scheduled watcher publishes `discvault-launcher:latest` for
`discvault:latest`, `discvault-launcher:dev` for `discvault:dev`,
`discvault-launcher:v26-beta` for `discvault:v26-beta`, and
`discvault-launcher:v26` for `discvault:v26`. Immutable release tags such as
`v26.0.0` can publish matching launcher and app images. With
`DISCVAULT_NEXT_IMAGE=auto` and `DISCVAULT_IMAGE=auto`, the launcher starts the
DiscVault app image baked into its own channel. Set `DISCVAULT_NEXT_IMAGE` to a
full image reference only when you want to override that channel intentionally.

`ghcr.io/helmerznl/discvault:latest` is the stable v26 stack image, not the old
single-container app. Every channel starts PostgreSQL, `next-api`,
`next-worker`, and `next-mcp`.

For stable passkeys, configure these values on the launcher and keep them
stable:

```text
RP_ID=app.discvault.eu
RP_ORIGIN=https://app.discvault.eu
RP_ORIGINS=https://app.discvault.eu
JWT_SECRET=<stable random secret, or leave empty once so the launcher persists one in /config/stack.env>
```

`RP_ID` must be the public domain only. `RP_ORIGIN` and `RP_ORIGINS` must match
the exact browser origin used for registration and login.

Channel mapping:

```text
discvault-launcher:latest    -> discvault:latest
discvault-launcher:dev       -> discvault:dev
discvault-launcher:v26-beta  -> discvault:v26-beta
discvault-launcher:v26       -> discvault:v26
discvault-launcher:v26.0.0   -> discvault:v26.0.0
```

Manual launcher builds can publish any matching channel:

```bash
gh workflow run "Build & Publish DiscVault Launcher" \
  -f stack_image=ghcr.io/helmerznl/discvault:v26.0.0 \
  -f launcher_tag=v26.0.0
```

## Manual Stack Removal

Removing the launcher container does not delete the managed stack. That protects
PostgreSQL data from accidental app removal.

To stop the managed stack manually:

```bash
docker compose --env-file /mnt/user/appdata/discvault-launcher/stack.env \
  -f /mnt/user/appdata/discvault-launcher/docker-compose.yml \
  -p discvault_stack down
```
