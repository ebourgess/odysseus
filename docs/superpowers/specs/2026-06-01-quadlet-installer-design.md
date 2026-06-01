# Quadlet Installer Design

## Goal

Create a project script that installs the current Docker Compose stack as
rootless Podman Quadlets. The script actively installs, reloads, builds, and
starts the stack. The containers must run on a dedicated Podman network so the
service names used by Odysseus remain private to the stack.

## Scope

The first implementation targets the services currently defined in
`docker-compose.yml`:

- `odysseus`, built from this repository's `Dockerfile`
- `chromadb`, from `docker.io/chromadb/chroma:latest`
- `searxng`, from `docker.io/searxng/searxng:latest`
- `ntfy`, from `docker.io/binwiederhier/ntfy`

The installer is project-specific rather than a general Compose-to-Quadlet
converter. This keeps behavior predictable for Compose features that do not
translate mechanically, including the local Odysseus build and SearXNG startup
initialization.

## Script Behavior

Add `scripts/install-quadlets.sh`. It will:

1. Resolve the repository root from the script location.
2. Create persistent host directories used by Odysseus:
   `data`, `data/ssh`, `data/huggingface`, `data/local`, and `logs`.
3. Create `.env` from `.env.example` when `.env` is missing.
4. Write Quadlet files to
   `$HOME/.config/containers/systemd/odysseus`.
5. Generate an isolated `odysseus.network` Quadlet.
6. Generate named volume Quadlets for ChromaDB, SearXNG, and ntfy.
7. Generate `odysseus-img.build` for the local application image.
8. Generate container Quadlets for all four services.
9. Run `systemctl --user daemon-reload`.
10. Start the image build service.
11. Start `chromadb`, `searxng`, `ntfy`, then `odysseus`.
12. Print status and smoke-test commands.

The script should be idempotent: rerunning it overwrites the generated Quadlet
files with the current desired configuration, reloads systemd, rebuilds the
image, and restarts the stack.

## Generated Quadlets

`odysseus.network` defines the private Podman network named `odysseus`. Each
container uses `Network=odysseus.network`.

`odysseus-img.build` builds `localhost/odysseus-img:latest` from the repository
root with the repository `Dockerfile`.

`odysseus.container` uses the built local image, mounts the same persistent
directories as Compose, reads `.env`, and sets:

- `SEARXNG_INSTANCE=http://searxng:8080`
- `CHROMADB_HOST=chromadb`
- `CHROMADB_PORT=8000`
- `PUID` and `PGID` from the current user unless already provided by `.env`

`searxng.container` preserves the Compose startup behavior that initializes
`/etc/searxng/settings.yml` from the repository template when needed.

`chromadb.container` and `ntfy.container` use named Podman volumes and match the
Compose environment and port defaults.

## Ports

The generated Quadlets preserve the Compose defaults:

- Odysseus: `${APP_PORT:-7000}:7000`
- ChromaDB: `${CHROMADB_BIND:-127.0.0.1}:8100:8000`
- SearXNG: `127.0.0.1:8080:8080`
- ntfy: `${NTFY_BIND:-127.0.0.1}:8091:80`

Because Quadlets do not expand `.env` variables inside `PublishPort=`, the
script resolves these values while writing the Quadlets. It sources `.env`
where possible and falls back to the defaults above.

## Error Handling

The script exits on errors, checks for required commands (`podman` and
`systemctl`), and refuses to run as root because the target is a rootless user
deployment. It reports the Quadlet output directory and the failing command
context through normal shell error output.

## Testing

Add shell-focused tests that validate generated content without requiring
Podman or systemd to be available. The installer will support a dry-run or
generation-only mode that writes to a caller-provided output directory and skips
service actions. Tests should verify:

- The network Quadlet is generated and every container references it.
- Port defaults are resolved correctly.
- Odysseus bind mounts include all persistent directories.
- SearXNG preserves its initialization entrypoint.
- The active install path would run reload, build, and start steps in order.

Manual verification after implementation:

```bash
scripts/install-quadlets.sh
systemctl --user status chromadb.service searxng.service ntfy.service odysseus.service
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
curl -fsS http://localhost:7000/api/health
```
