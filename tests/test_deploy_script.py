"""Tests for the blue-green deployment scripts.

The real deploy.sh / rollback.sh are executed, but `docker` and `curl` are
replaced with small fake programs. The fakes simulate containers becoming
healthy (or not) so we can check the switching, health-check, rollback and
locking logic without a real server.
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
DEPLOY = ROOT / "deployment" / "deploy.sh"
ROLLBACK = ROOT / "deployment" / "rollback.sh"
BLUE, GREEN = "127.0.0.1:5001", "127.0.0.1:5002"

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="bash is required")

# --------------------------------------------------------------------------- fakes
FAKE_DOCKER = textwrap.dedent("""\
    #!PYTHON
    # Fake `docker`: remembers build args and "starts" containers by writing
    # the /health response each one would return.
    import json, os, sys
    fake = os.environ["FAKE_DIR"]
    args = sys.argv[1:]
    with open(os.path.join(fake, "calls.log"), "a") as f:
        f.write(" ".join(args) + "\\n")
    ports = {"blue": 5001, "green": 5002}

    if args and args[0] == "build":
        image = args[args.index("-t") + 1]
        build_args = dict(a.split("=", 1) for i, a in enumerate(args) if args[i - 1] == "--build-arg")
        os.makedirs(os.path.join(fake, "images"), exist_ok=True)
        with open(os.path.join(fake, "images", image.replace(":", "_")), "w") as f:
            json.dump(build_args, f)
    elif args and args[0] == "compose" and "up" in args:
        if os.path.exists(os.path.join(fake, "compose_fail")):
            sys.exit(1)
        color = args[-1].replace("shopflow-", "")
        env_file = args[args.index("--env-file") + 1]
        env = dict(l.strip().split("=", 1) for l in open(env_file) if "=" in l)
        image = env[color.upper() + "_IMAGE"]
        build = json.load(open(os.path.join(fake, "images", image.replace(":", "_"))))
        if build.get("SIMULATE_UNHEALTHY") == "true":
            body = "UNHEALTHY"
        else:
            body = json.dumps({"build": build["BUILD_SHA"], "color": color,
                               "release": build["RELEASE_ID"], "status": "healthy",
                               "version": build["APP_VERSION"]}, separators=(",", ":"))
        with open(os.path.join(fake, "health_%d" % ports[color]), "w") as f:
            f.write(body)
    elif args and args[0] == "stop":
        color = args[-1].replace("shopflow-", "")
        try:
            os.remove(os.path.join(fake, "health_%d" % ports[color]))
        except FileNotFoundError:
            pass
    sys.exit(0)
""")

FAKE_CURL = textwrap.dedent("""\
    #!PYTHON
    # Fake `curl`: answers /health for the "running" containers. The public
    # URL is routed according to the Nginx upstream file, like real Nginx.
    import os, re, sys
    fake = os.environ["FAKE_DIR"]
    url = [a for a in sys.argv[1:] if a.startswith("http")][-1]
    m = re.match(r"http://127\\.0\\.0\\.1:(500[12])/", url)
    if m:
        port = m.group(1)
    else:  # public URL -> goes through "nginx"
        if os.path.exists(os.path.join(fake, "proxy_broken")):
            sys.exit(22)
        upstream = open(os.environ["NGINX_UPSTREAM_FILE"]).read()
        port = re.search(r"127\\.0\\.0\\.1:(500[12])", upstream).group(1)
    path = os.path.join(fake, "health_" + port)
    if not os.path.exists(path):
        sys.exit(7)            # connection refused
    body = open(path).read()
    if body == "UNHEALTHY":
        sys.exit(22)           # HTTP 503 with -f
    print(body)
""")


def _write_exec(path: Path, content: str):
    path.write_text(content.replace("#!PYTHON", "#!/usr/bin/env python3"))
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


@pytest.fixture
def env(tmp_path):
    fake = tmp_path / "fake"
    bin_dir = tmp_path / "bin"
    nginx_dir = tmp_path / "nginx"
    for d in (fake, bin_dir, nginx_dir):
        d.mkdir()
    _write_exec(bin_dir / "docker", FAKE_DOCKER)
    _write_exec(bin_dir / "curl", FAKE_CURL)
    upstream = nginx_dir / "active_upstream.conf"
    upstream.write_text(f"server {BLUE};\n")  # what Ansible installs initially

    return {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "FAKE_DIR": str(fake),
        "SHOPFLOW_HOME": str(tmp_path / "home"),
        "NGINX_UPSTREAM_FILE": str(upstream),
        "NGINX_TEST_CMD": "true",
        "NGINX_RELOAD_CMD": "true",
        "PUBLIC_HEALTH_URL": "http://shopflow.test/health",
        "HEALTH_RETRIES": "2", "HEALTH_INTERVAL": "0",
        "VERIFY_ATTEMPTS": "4", "VERIFY_REQUIRED": "2", "VERIFY_INTERVAL": "0",
        "APP_VERSION": "1.0.0", "BUILD_SHA": "abc1234",
    }


def run(script, env, *args, **overrides):
    result = subprocess.run(["bash", str(script), *args], env={**env, **overrides},
                            capture_output=True, text=True, timeout=60)
    result.output = result.stdout + result.stderr
    return result


def upstream(env):
    return Path(env["NGINX_UPSTREAM_FILE"]).read_text()


def running(env, port):
    return (Path(env["FAKE_DIR"]) / f"health_{port}").exists()


def state(env, name):
    return (Path(env["SHOPFLOW_HOME"]) / "state" / name).read_text()


# --------------------------------------------------------------------------- deploy
def test_first_deploy_switches_traffic_to_green(env):
    result = run(DEPLOY, env)
    assert result.returncode == 0, result.output
    assert GREEN in upstream(env)
    assert state(env, "active_color").strip() == "green"
    assert "SUCCESS" in state(env, "deployments.log")
    assert "DEPLOYMENT SUCCESSFUL" in result.output


def test_second_deploy_goes_to_blue_and_keeps_green_as_standby(env):
    assert run(DEPLOY, env).returncode == 0
    result = run(DEPLOY, env, APP_VERSION="1.1.0")
    assert result.returncode == 0, result.output
    assert BLUE in upstream(env)
    assert running(env, 5002), "previous colour must stay up for instant rollback"
    assert "v1.1.0 is live on BLUE" in result.output


def test_secret_key_is_generated_once_and_reused(env):
    run(DEPLOY, env)
    key = state(env, "compose.env").split("SECRET_KEY=")[1].split()[0]
    run(DEPLOY, env)
    assert len(key) == 64
    assert state(env, "compose.env").count("SECRET_KEY=") == 1
    assert f"SECRET_KEY={key}" in state(env, "compose.env")


def test_unhealthy_release_never_receives_traffic(env):
    assert run(DEPLOY, env).returncode == 0          # green is live
    result = run(DEPLOY, env, "--simulate-failure")  # broken release -> blue
    assert result.returncode != 0
    assert "Traffic was NOT switched" in result.output
    assert GREEN in upstream(env), "traffic must stay on the healthy version"
    assert not running(env, 5001), "the broken container should be stopped"
    assert running(env, 5002)
    assert "BLUE_IMAGE=shopflow:none" in state(env, "compose.env")
    assert "FAILED_HEALTHCHECK" in state(env, "deployments.log")


def test_failure_after_switch_restores_previous_nginx_config(env):
    assert run(DEPLOY, env).returncode == 0          # green is live
    (Path(env["FAKE_DIR"]) / "proxy_broken").touch() # checks through nginx now fail
    result = run(DEPLOY, env)
    assert result.returncode != 0
    assert "AUTOMATIC ROLLBACK" in result.output
    assert GREEN in upstream(env), "previous upstream must be restored"
    assert "ROLLED_BACK" in state(env, "deployments.log")


def test_invalid_nginx_config_is_not_kept(env):
    assert run(DEPLOY, env).returncode == 0          # green is live
    result = run(DEPLOY, env, NGINX_TEST_CMD="false")
    assert result.returncode != 0
    assert GREEN in upstream(env)


def test_container_that_fails_to_start_is_not_switched_to(env):
    (Path(env["FAKE_DIR"]) / "compose_fail").touch()
    result = run(DEPLOY, env)
    assert result.returncode != 0
    assert BLUE in upstream(env)  # unchanged


def test_two_deployments_cannot_run_at_the_same_time(env):
    lock = Path(env["SHOPFLOW_HOME"]) / "state" / "deploy.lock"
    lock.mkdir(parents=True)
    (lock / "pid").write_text(str(os.getpid()))      # a live process holds the lock
    result = run(DEPLOY, env)
    assert result.returncode != 0
    assert "already running" in result.output
    assert lock.exists(), "must not remove another deployment's lock"
    assert BLUE in upstream(env)


def test_stale_lock_from_crashed_deployment_is_cleared(env):
    lock = Path(env["SHOPFLOW_HOME"]) / "state" / "deploy.lock"
    lock.mkdir(parents=True)
    (lock / "pid").write_text("999999")              # process no longer exists
    result = run(DEPLOY, env)
    assert result.returncode == 0, result.output
    assert not lock.exists(), "lock is released when the deployment ends"


# --------------------------------------------------------------------------- rollback
def test_rollback_switches_back_to_standby(env):
    run(DEPLOY, env)                                 # green
    run(DEPLOY, env)                                 # blue live, green standby
    result = run(ROLLBACK, env)
    assert result.returncode == 0, result.output
    assert GREEN in upstream(env)
    assert "ROLLBACK COMPLETE" in result.output


def test_rollback_refused_when_standby_is_not_running(env):
    run(DEPLOY, env)                                 # green live, blue never started
    result = run(ROLLBACK, env)
    assert result.returncode != 0
    assert "rollback is not possible" in result.output
    assert GREEN in upstream(env)
