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


def test_active_install_logs_reload_build_and_start_order(tmp_path):
    output_dir = tmp_path / "quadlets"
    command_log = tmp_path / "commands.log"
    home = tmp_path / "home"
    home.mkdir()

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
        env={
            "HOME": str(home),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        },
    )

    assert result.returncode == 0, result.stderr
    assert command_log.read_text().splitlines() == [
        "systemctl --user daemon-reload",
        "systemctl --user start odysseus-img-build.service",
        "systemctl --user restart chromadb.service searxng.service ntfy.service",
        "systemctl --user restart odysseus.service",
    ]
