# DiscVault Launcher

DiscVault Launcher is a small deployment manager for the PostgreSQL-backed
DiscVault stack. It is intentionally separate from the DiscVault application
image and from the standalone Docker Compose stack.

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
      -> postgres
      -> next-api
      -> next-worker
    -> Nginx proxy on the Unraid WebUI port
```

The launcher keeps running as the public web endpoint and proxies requests to
`next-api:5000`. The managed stack does not bind its own host ports in launcher
mode, so an existing Unraid WebUI port such as `6080` stays stable.

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
  ghcr.io/helmerznl/discvault-launcher:beta
```

The first start writes generated secrets to `/config/stack.env`. Keep that file
stable; it contains the PostgreSQL password and JWT secret used by the stack.

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
That workflow checks the `DISCVAULT_IMAGE` channel digest and republishes the
launcher tag when the stack image changes.

1. `Stack Image Update Watch` sees a new `helmerznl/discvault` digest and
   republishes `helmerznl/discvault-launcher:beta`.
2. Unraid detects the launcher image update.
3. Community Apps or the Auto Update plugin updates the launcher container.
4. The launcher starts and pulls `DISCVAULT_IMAGE`.
5. The launcher runs `docker compose up -d --remove-orphans` for project
   `discvault_stack`.
6. `next-api` applies PostgreSQL migrations before serving traffic.
7. The existing beta data stays in place and is imported by the migration UI.

By default the launcher stores the packaged stack digest in
`/config/last-stack-digest` after a successful start. When a newer launcher
image represents a different stack digest, it adds `--force-recreate` after
pulling so the managed services definitely restart on the freshly pulled image.
It also compares the local `DISCVAULT_IMAGE` image ID before and after pulling,
and checks whether `next-api` and `next-worker` use that local image ID. Set
`DISCVAULT_FORCE_RECREATE_ON_PULL=false` to disable that behavior.

For troubleshooting or aggressive test deployments, set
`DISCVAULT_ALWAYS_RECREATE_STACK=true`. That forces `--force-recreate` on every
launcher start after pulling.

Manual testing with the current Next channel can republish the beta launcher
when the development stack image changes. Use this while the Unraid template is
still installed as `discvault-launcher:beta` but `DISCVAULT_IMAGE` points to
`ghcr.io/helmerznl/discvault:dev`:

```bash
gh workflow run "Stack Image Update Watch" \
  -f stack_image=ghcr.io/helmerznl/discvault:dev \
  -f launcher_tag=beta \
  -f force=true
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
