# Quadlet Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `scripts/install-quadlets.sh`, an idempotent rootless Podman Quadlet installer for the current Odysseus Docker Compose stack.

**Architecture:** The installer is a focused Bash script with pure generation functions and a thin active-install wrapper. Tests run the script in generation-only and command-log modes so Quadlet content and service ordering are verified without requiring Podman or systemd.

**Tech Stack:** Bash, pytest, temporary filesystem fixtures, rootless Podman Quadlet file formats.

---

## File Structure

- Create `scripts/install-quadlets.sh`: resolves repo paths, reads `.env`, writes Quadlet files, optionally logs service commands, and performs install/reload/build/start in normal mode.
- Create `tests/test_quadlet_installer.py`: pytest tests invoking the script with temporary output directories and command-log mode.
- Modify `docs/podman-quadlets-runbook.md` only if the final script changes commands users should run. No runbook edit is required for the initial implementation.

## Script Interface

The script supports these arguments:

```bash
scripts/install-quadlets.sh
scripts/install-quadlets.sh --generate-only --output-dir /tmp/quadlets
scripts/install-quadlets.sh --generate-only --output-dir /tmp/quadlets --env-file /tmp/app.env
scripts/install-quadlets.sh --command-log /tmp/commands.log --output-dir /tmp/quadlets
```

`--generate-only` writes Quadlets and exits before command checks or service actions.

`--env-file FILE` sources values from a caller-provided env file for generation.
The generated Odysseus Quadlet still uses `EnvironmentFile=<repo>/.env` because
that is the runtime env file for the installed stack. This option exists so
tests and automation can resolve generated ports without mutating the repo's
real `.env`.

`--command-log FILE` writes the install commands that would run, instead of executing `systemctl`, and is used by tests.

## Task 1: Add Generation Tests

**Files:**
- Create: `tests/test_quadlet_installer.py`
- Create later: `scripts/install-quadlets.sh`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_quadlet_installer.py`:

```python
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "install-quadlets.sh"


def run_installer(tmp_path, *args, env_file_content=None, env=None):
    output_dir = tmp_path / "quadlets"
    home = tmp_path / "home"
    home.mkdir()
    command = [
        str(SCRIPT),
        "--generate-only",
        "--output-dir",
        str(output_dir),
        *args,
    ]
    if env_file_content is not None:
        env_file = tmp_path / "app.env"
        env_file.write_text(env_file_content)
        command.extend(["--env-file", str(env_file)])
    merged_env = {
        "HOME": str(home),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }
    if env:
        merged_env.update(env)
    result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=merged_env,
    )
    assert result.returncode == 0, result.stderr
    return output_dir


def read(output_dir, name):
    return (output_dir / name).read_text()


def test_generates_isolated_network_and_attaches_every_container(tmp_path):
    output_dir = run_installer(tmp_path)

    assert "NetworkName=odysseus" in read(output_dir, "odysseus.network")
    for name in [
        "odysseus.container",
        "chromadb.container",
        "searxng.container",
        "ntfy.container",
    ]:
        assert "Network=odysseus.network" in read(output_dir, name)


def test_resolves_default_ports_and_env_overrides(tmp_path):
    output_dir = run_installer(
        tmp_path,
        env_file_content=(
            "APP_PORT=7500\n"
            "CHROMADB_BIND=0.0.0.0\n"
            "NTFY_BIND=0.0.0.0\n"
        ),
    )

    assert "PublishPort=7500:7000" in read(output_dir, "odysseus.container")
    assert "PublishPort=0.0.0.0:8100:8000" in read(output_dir, "chromadb.container")
    assert "PublishPort=127.0.0.1:8080:8080" in read(output_dir, "searxng.container")
    assert "PublishPort=0.0.0.0:8091:80" in read(output_dir, "ntfy.container")


def test_odysseus_mounts_persistent_directories_and_env_file(tmp_path):
    output_dir = run_installer(tmp_path)
    content = read(output_dir, "odysseus.container")

    assert f"EnvironmentFile={REPO_ROOT}/.env" in content
    assert f"Volume={REPO_ROOT}/data:/app/data:Z" in content
    assert f"Volume={REPO_ROOT}/logs:/app/logs:Z" in content
    assert f"Volume={REPO_ROOT}/data/ssh:/app/.ssh:Z" in content
    assert f"Volume={REPO_ROOT}/data/huggingface:/app/.cache/huggingface:Z" in content
    assert f"Volume={REPO_ROOT}/data/local:/app/.local:Z" in content


def test_searxng_preserves_compose_initialization_entrypoint(tmp_path):
    output_dir = run_installer(tmp_path)
    content = read(output_dir, "searxng.container")

    assert "Exec=/bin/sh -c" in content
    assert "odysseus-local-searxng-json-2026-05-30" in content
    assert "__SEARXNG_SECRET__" in content
    assert "/tmp/searxng-settings.yml.template" in content
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
pytest tests/test_quadlet_installer.py -q
```

Expected: FAIL because `scripts/install-quadlets.sh` does not exist.

## Task 2: Implement Generation Mode

**Files:**
- Create: `scripts/install-quadlets.sh`
- Test: `tests/test_quadlet_installer.py`

- [ ] **Step 1: Write minimal implementation**

Create `scripts/install-quadlets.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${HOME}/.config/containers/systemd/odysseus"
GENERATE_ONLY=0
COMMAND_LOG=""

usage() {
  cat <<'USAGE'
Usage: scripts/install-quadlets.sh [--generate-only] [--output-dir DIR] [--command-log FILE]
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --generate-only)
      GENERATE_ONLY=1
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:?missing value for --env-file}"
      shift 2
      ;;
    --command-log)
      COMMAND_LOG="${2:?missing value for --command-log}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

load_env_file() {
  local env_file="${ENV_FILE:-$REPO_ROOT/.env}"
  [ -f "$env_file" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
}

write_file() {
  local name="$1"
  mkdir -p "$OUTPUT_DIR"
  cat > "$OUTPUT_DIR/$name"
}

ensure_project_state() {
  mkdir -p "$REPO_ROOT/data" "$REPO_ROOT/data/ssh" "$REPO_ROOT/data/huggingface" "$REPO_ROOT/data/local" "$REPO_ROOT/logs"
  chmod 700 "$REPO_ROOT/data/ssh"
  if [ ! -f "$REPO_ROOT/.env" ] && [ -f "$REPO_ROOT/.env.example" ]; then
    cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
  fi
}

generate_quadlets() {
  load_env_file
  local app_port="${APP_PORT:-7000}"
  local chromadb_bind="${CHROMADB_BIND:-127.0.0.1}"
  local ntfy_bind="${NTFY_BIND:-127.0.0.1}"
  local puid="${PUID:-$(id -u)}"
  local pgid="${PGID:-$(id -g)}"

  write_file odysseus.network <<'EOF'
[Network]
NetworkName=odysseus
EOF

  write_file chromadb-data.volume <<'EOF'
[Volume]
VolumeName=odysseus-chromadb-data
EOF

  write_file searxng-data.volume <<'EOF'
[Volume]
VolumeName=odysseus-searxng-data
EOF

  write_file ntfy-cache.volume <<'EOF'
[Volume]
VolumeName=odysseus-ntfy-cache
EOF

  write_file odysseus-img.build <<EOF
[Build]
ImageTag=localhost/odysseus-img:latest
File=${REPO_ROOT}/Dockerfile
SetWorkingDirectory=${REPO_ROOT}

[Service]
TimeoutStartSec=1800
EOF

  write_file chromadb.container <<EOF
[Unit]
Description=Odysseus ChromaDB

[Container]
Image=docker.io/chromadb/chroma:latest
ContainerName=chromadb
Network=odysseus.network
PublishPort=${chromadb_bind}:8100:8000
Volume=chromadb-data.volume:/chroma/chroma
Environment=ANONYMIZED_TELEMETRY=FALSE

[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=default.target
EOF

  write_file ntfy.container <<EOF
[Unit]
Description=Odysseus ntfy

[Container]
Image=docker.io/binwiederhier/ntfy
ContainerName=ntfy
Network=odysseus.network
PublishPort=${ntfy_bind}:8091:80
Exec=serve
Volume=ntfy-cache.volume:/var/cache/ntfy
Environment=NTFY_BASE_URL=${NTFY_BASE_URL:-http://localhost:8091}

[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=default.target
EOF

  write_file searxng.container <<EOF
[Unit]
Description=Odysseus SearXNG

[Container]
Image=docker.io/searxng/searxng:latest
ContainerName=searxng
Network=odysseus.network
PublishPort=127.0.0.1:8080:8080
Exec=/bin/sh -c 'set -eu; if [ ! -s /etc/searxng/settings.yml ] || grep -q '"'"'odysseus-local-searxng-json-2026-05-30\|__SEARXNG_SECRET__'"'"' /etc/searxng/settings.yml; then secret="\${SEARXNG_SECRET:-}"; if [ -z "\$secret" ]; then secret="\$(python -c '"'"'import secrets; print(secrets.token_urlsafe(48))'"'"')"; fi; sed "s|__SEARXNG_SECRET__|\$secret|g" /tmp/searxng-settings.yml.template > /etc/searxng/settings.yml; fi; exec /usr/local/searxng/entrypoint.sh'
Volume=searxng-data.volume:/etc/searxng
Volume=${REPO_ROOT}/config/searxng/settings.yml:/tmp/searxng-settings.yml.template:ro,Z
Environment=SEARXNG_BASE_URL=http://localhost:8080/
Environment=SEARXNG_SECRET=${SEARXNG_SECRET:-}
HealthCmd=python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/', timeout=5).read(1)"
HealthInterval=5s
HealthTimeout=6s
HealthRetries=20
HealthStartPeriod=10s

[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=default.target
EOF

  write_file odysseus.container <<EOF
[Unit]
Description=Odysseus
Requires=searxng.service chromadb.service
After=searxng.service chromadb.service

[Container]
Image=localhost/odysseus-img:latest
ContainerName=odysseus
Network=odysseus.network
PublishPort=${app_port}:7000
Volume=${REPO_ROOT}/data:/app/data:Z
Volume=${REPO_ROOT}/logs:/app/logs:Z
Volume=${REPO_ROOT}/data/ssh:/app/.ssh:Z
Volume=${REPO_ROOT}/data/huggingface:/app/.cache/huggingface:Z
Volume=${REPO_ROOT}/data/local:/app/.local:Z
AddHost=host.docker.internal:host-gateway
EnvironmentFile=${REPO_ROOT}/.env
Environment=SEARXNG_INSTANCE=http://searxng:8080
Environment=CHROMADB_HOST=chromadb
Environment=CHROMADB_PORT=8000
Environment=PUID=${puid}
Environment=PGID=${pgid}

[Service]
Restart=on-failure
RestartSec=10s
TimeoutStartSec=600

[Install]
WantedBy=default.target
EOF
}

main() {
  ensure_project_state
  generate_quadlets

  if [ "$GENERATE_ONLY" -eq 1 ]; then
    echo "Generated Quadlets in $OUTPUT_DIR"
    exit 0
  fi
}

main "$@"
```

- [ ] **Step 2: Make the script executable**

Run:

```bash
chmod +x scripts/install-quadlets.sh
```

- [ ] **Step 3: Run tests to verify generation passes**

Run:

```bash
pytest tests/test_quadlet_installer.py -q
```

Expected: PASS for all generation tests.

- [ ] **Step 4: Commit**

Run:

```bash
git add scripts/install-quadlets.sh tests/test_quadlet_installer.py
git commit -m "feat: generate podman quadlets"
```

## Task 3: Add Active Install Ordering Tests

**Files:**
- Modify: `tests/test_quadlet_installer.py`
- Modify: `scripts/install-quadlets.sh`

- [ ] **Step 1: Write the failing active-install test**

Append to `tests/test_quadlet_installer.py`:

```python
def test_active_install_logs_reload_build_and_start_order(tmp_path):
    output_dir = tmp_path / "quadlets"
    command_log = tmp_path / "commands.log"

    result = subprocess.run(
        [
            str(SCRIPT),
            "--output-dir",
            str(output_dir),
            "--command-log",
            str(command_log),
        ],
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    assert result.returncode == 0, result.stderr
    assert command_log.read_text().splitlines() == [
        "systemctl --user daemon-reload",
        "systemctl --user start odysseus-img-build.service",
        "systemctl --user restart chromadb.service searxng.service ntfy.service",
        "systemctl --user restart odysseus.service",
    ]
```

- [ ] **Step 2: Run the active-install test to verify it fails**

Run:

```bash
pytest tests/test_quadlet_installer.py::test_active_install_logs_reload_build_and_start_order -q
```

Expected: FAIL because `--command-log` does not yet log install commands.

## Task 4: Implement Active Install Mode

**Files:**
- Modify: `scripts/install-quadlets.sh`
- Test: `tests/test_quadlet_installer.py`

- [ ] **Step 1: Add command execution helpers**

In `scripts/install-quadlets.sh`, add these functions before `main`:

```bash
require_non_root_install() {
  if [ "$(id -u)" = "0" ]; then
    echo "This installer targets rootless Podman and must not be run as root." >&2
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

run_cmd() {
  if [ -n "$COMMAND_LOG" ]; then
    printf '%s\n' "$*" >> "$COMMAND_LOG"
  else
    "$@"
  fi
}

install_stack() {
  if [ -z "$COMMAND_LOG" ]; then
    require_non_root_install
    require_command podman
    require_command systemctl
  else
    : > "$COMMAND_LOG"
  fi

  run_cmd systemctl --user daemon-reload
  run_cmd systemctl --user start odysseus-img-build.service
  run_cmd systemctl --user restart chromadb.service searxng.service ntfy.service
  run_cmd systemctl --user restart odysseus.service
}
```

Then update `main` to call `install_stack` after generation:

```bash
main() {
  ensure_project_state
  generate_quadlets

  if [ "$GENERATE_ONLY" -eq 1 ]; then
    echo "Generated Quadlets in $OUTPUT_DIR"
    exit 0
  fi

  install_stack
  cat <<EOF
Installed Quadlets in $OUTPUT_DIR

Verify with:
  systemctl --user status chromadb.service searxng.service ntfy.service odysseus.service
  podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  curl -fsS http://localhost:${APP_PORT:-7000}/api/health
EOF
}
```

- [ ] **Step 2: Run the active-install test to verify it passes**

Run:

```bash
pytest tests/test_quadlet_installer.py::test_active_install_logs_reload_build_and_start_order -q
```

Expected: PASS.

- [ ] **Step 3: Run all Quadlet installer tests**

Run:

```bash
pytest tests/test_quadlet_installer.py -q
```

Expected: PASS.

- [ ] **Step 4: Commit**

Run:

```bash
git add scripts/install-quadlets.sh tests/test_quadlet_installer.py
git commit -m "feat: install podman quadlets"
```

## Task 5: Final Verification

**Files:**
- Read: `scripts/install-quadlets.sh`
- Read: `tests/test_quadlet_installer.py`

- [ ] **Step 1: Run focused tests**

Run:

```bash
pytest tests/test_quadlet_installer.py -q
```

Expected: PASS.

- [ ] **Step 2: Run a generation smoke test**

Run:

```bash
tmpdir="$(mktemp -d)"
scripts/install-quadlets.sh --generate-only --output-dir "$tmpdir"
find "$tmpdir" -maxdepth 1 -type f -print | sort
```

Expected output includes:

```text
chromadb-data.volume
chromadb.container
ntfy-cache.volume
ntfy.container
odysseus-img.build
odysseus.container
odysseus.network
searxng-data.volume
searxng.container
```

- [ ] **Step 3: Review git diff**

Run:

```bash
git diff -- scripts/install-quadlets.sh tests/test_quadlet_installer.py
```

Expected: only the installer and tests changed since the implementation commits.

- [ ] **Step 4: Report manual install command**

Tell the user the active command is:

```bash
scripts/install-quadlets.sh
```

Also tell them this command writes to `$HOME/.config/containers/systemd/odysseus`, runs `systemctl --user daemon-reload`, builds the local image, and restarts the generated services.
