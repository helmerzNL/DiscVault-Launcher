# DiscVault Launcher

DiscVault Launcher is a small deployment manager for DiscVault Docker channels.
It can run the legacy single-container app for `latest`/`legacy`, or the
PostgreSQL-backed DiscVault 26 stack for v26 channels. It is intentionally
separate from the DiscVault application image and from the standalone Docker
Compose stack.

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
      -> legacy latest: discvault
      -> v26 stack: postgres + next-api + next-worker
    -> Nginx proxy on the Unraid WebUI port
```

The launcher keeps running as the public web endpoint and proxies requests to
the managed DiscVault container. Legacy mode proxies to the all-in-one
container on port `80`; v26 stack mode proxies to `next-api:5000`. The managed
containers do not bind their own host ports in launcher mode, so an existing
Unraid WebUI port such as `6080` stays stable.

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
In legacy `latest`/`legacy` mode, the same generated `JWT_SECRET`, `RP_ID`,
`RP_ORIGIN`, and `RP_ORIGINS` values are passed through to the actual
`discvault:latest` app container so existing passkeys keep working after a
launcher restart.

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
5. For `latest`/`legacy`, the launcher starts only the legacy DiscVault
   all-in-one container.
6. For `dev`, `v26-beta`, `v26`, and immutable `v26.x.y` tags, the launcher
   runs the PostgreSQL-backed v26 stack.
7. In v26 mode, `next-api` applies PostgreSQL migrations before serving
   traffic.
8. The existing beta data stays in place and is imported by the migration UI.

The launcher resolves image rollouts in this order:

1. `DISCVAULT_NEXT_IMAGE` (primary override for v26 stack deployments).
2. `DISCVAULT_IMAGE` (fallback, including `auto` behavior).
3. Launcher-packaged default image for the current channel.

If no override is set, the safe default is `ghcr.io/helmerznl/discvault:latest`.
Manual GitHub Actions launcher publishes should therefore default to baking in
`discvault:latest` unless a different DiscVault image is intentionally selected.

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

### Temporary workaround / explicit pinning

Until your target image channel has the fix live, you can force a deterministic
build by pinning a digest in `/config/stack.env`:

```env
DISCVAULT_NEXT_IMAGE=ghcr.io/helmerznl/discvault:v26-beta@sha256:<digest>
```

Then recreate by restarting the launcher container.

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

`ghcr.io/helmerznl/discvault:latest` is the legacy single-container app. When
the launcher resolves to `discvault:latest` or `discvault:legacy`, it starts
only that one container and does not pull or start PostgreSQL, `next-api`, or
`next-worker`.

For legacy passkeys, configure these values on the launcher and keep them
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
discvault-launcher:latest    -> discvault:latest    (legacy single container)
discvault-launcher:legacy    -> discvault:latest    (legacy single container)
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
