import os
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "install-quadlets.sh"


def run_installer(tmp_path, *args, env=None):
    output_dir = tmp_path / "quadlets"
    command = [str(SCRIPT), "--generate-only", "--output-dir", str(output_dir), *args]
    merged_env = os.environ.copy()
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
    env_file = REPO_ROOT / ".env"
    original = env_file.read_text() if env_file.exists() else None
    try:
        env_file.write_text(
            "APP_PORT=7500\n"
            "CHROMADB_BIND=0.0.0.0\n"
            "NTFY_BIND=0.0.0.0\n"
        )
        output_dir = run_installer(tmp_path)
    finally:
        if original is None:
            env_file.unlink(missing_ok=True)
        else:
            env_file.write_text(original)

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
