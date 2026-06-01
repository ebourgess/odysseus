#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${HOME}/.config/containers/systemd/odysseus"
GENERATE_ONLY=0
ENV_FILE=""
COMMAND_LOG=""

usage() {
  cat <<'USAGE'
Usage: scripts/install-quadlets.sh [--generate-only] [--output-dir DIR] [--env-file FILE] [--command-log FILE]

Options:
  --generate-only   Generate Quadlet files and exit.
  --output-dir DIR  Write generated Quadlet files to DIR.
  --env-file FILE   Read generation-time KEY=VALUE inputs from FILE.
                   Generated odysseus.container still uses the runtime
                   EnvironmentFile at the repository .env.
  --command-log FILE
                   Write active install commands to FILE instead of executing.
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
  local line key value first last

  [ -f "$env_file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    line="${line#"${line%%[![:space:]]*}"}"
    if [[ "$line" =~ ^export[[:space:]]+(.+)$ ]]; then
      line="${BASH_REMATCH[1]}"
    fi

    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case "$key" in
      APP_PORT|CHROMADB_BIND|NTFY_BIND|NTFY_BASE_URL|SEARXNG_SECRET|PUID|PGID)
        ;;
      *)
        continue
        ;;
    esac

    if [ "${#value}" -ge 2 ]; then
      first="${value:0:1}"
      last="${value: -1}"
      if { [ "$first" = "'" ] && [ "$last" = "'" ]; } || { [ "$first" = '"' ] && [ "$last" = '"' ]; }; then
        value="${value:1:${#value}-2}"
      fi
    fi

    export "$key=$value"
  done < "$env_file"
}

write_file() {
  local name="$1"
  mkdir -p "$OUTPUT_DIR"
  cat > "$OUTPUT_DIR/$name"
}

ensure_project_state() {
  mkdir -p \
    "$REPO_ROOT/data" \
    "$REPO_ROOT/data/ssh" \
    "$REPO_ROOT/data/huggingface" \
    "$REPO_ROOT/data/local" \
    "$REPO_ROOT/logs"
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
  local ntfy_base_url="${NTFY_BASE_URL:-http://localhost:8091}"
  local searxng_secret="${SEARXNG_SECRET:-}"
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
Environment=NTFY_BASE_URL=${ntfy_base_url}

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
Environment=SEARXNG_SECRET=${searxng_secret}
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

refuse_root_for_active_install() {
  if [ "$(id -u)" -eq 0 ]; then
    echo "Refusing to run active rootless install as root." >&2
    exit 1
  fi
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
}

prepare_command_log() {
  [ -n "$COMMAND_LOG" ] || return 0
  mkdir -p "$(dirname "$COMMAND_LOG")"
  : > "$COMMAND_LOG"
}

run_cmd() {
  if [ -n "$COMMAND_LOG" ]; then
    printf '%s\n' "$*" >> "$COMMAND_LOG"
    return 0
  fi

  "$@"
}

active_install() {
  if [ -z "$COMMAND_LOG" ]; then
    refuse_root_for_active_install
    require_command podman
    require_command systemctl
  fi

  prepare_command_log
  run_cmd systemctl --user daemon-reload
  run_cmd systemctl --user start odysseus-img-build.service
  run_cmd systemctl --user restart chromadb.service searxng.service ntfy.service
  run_cmd systemctl --user restart odysseus.service
}

print_success() {
  cat <<EOF
Installed Quadlets in $OUTPUT_DIR

Verify with:
  systemctl --user status odysseus.service
  podman ps
  journalctl --user -u odysseus.service -f
EOF
}

main() {
  ensure_project_state
  generate_quadlets

  if [ "$GENERATE_ONLY" -eq 1 ]; then
    echo "Generated Quadlets in $OUTPUT_DIR"
    exit 0
  fi

  active_install
  print_success
}

main "$@"
