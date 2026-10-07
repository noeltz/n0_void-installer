"""Exercise Wayfire autostart and GUI/tty setup coordination with a PTY kitty."""
import fcntl
import json
import os
import pathlib
import pwd
import subprocess
import tempfile
import time

text = (pathlib.Path(__file__).resolve().parents[1] / "install.sh").read_text()


def embedded(tag):
    return text.split("<<'" + tag + "'\n", 1)[1].split("\n" + tag, 1)[0]


def wait_ready(path, process):
    deadline = time.monotonic() + 5
    while not path.exists() and time.monotonic() < deadline:
        assert process.poll() is None, process.communicate()
        time.sleep(0.02)
    assert path.exists(), "kitty fixture did not start"


with tempfile.TemporaryDirectory(prefix="void-gui-chezmoi-") as directory:
    root = pathlib.Path(directory)
    user = pwd.getpwuid(os.getuid()).pw_name
    config = root / "chezmoi.conf"
    config.write_text(f"USERNAME={user}\nREPOSITORY=example/dotfiles\n")
    helper = root / "helper"
    helper.write_text(embedded("CHEZMOI_EOF").replace("/etc/void-installer/chezmoi.conf", str(config)))
    helper.chmod(0o755)
    gui = root / "gui"
    gui.write_text(embedded("CHEZMOI_GUI_EOF")
                   .replace("/etc/void-installer/chezmoi.conf", str(config))
                   .replace("/usr/local/sbin/void-installer-chezmoi", str(helper)))
    gui.chmod(0o755)
    bin_dir = root / "bin"
    bin_dir.mkdir()
    chezmoi = bin_dir / "chezmoi"
    chezmoi.write_text("""#!/bin/bash
printf '%s\n' "$*" >> "$CALL_LOG"
if [[ $1 == init ]]; then mkdir -p "$HOME/.local/share/chezmoi"; fi
exit "${CHEZMOI_RC:-0}"
""")
    chezmoi.chmod(0o755)
    kitty = bin_dir / "kitty"
    kitty.write_text("""#!/usr/bin/env python3
import errno, json, os, pathlib, pty, subprocess, sys, time
with open(os.environ["KITTY_CALLS"], "a") as file:
    file.write(json.dumps(sys.argv[1:]) + "\\n")
master, slave = pty.openpty()
process = subprocess.Popen([sys.argv[-1]], stdin=slave, stdout=slave, stderr=slave)
os.close(slave)
output = bytearray()
while True:
    try: chunk = os.read(master, 4096)
    except OSError as e:
        if e.errno == errno.EIO: break
        raise
    if not chunk: break
    output.extend(chunk)
os.close(master)
pathlib.Path(os.environ["PTY_OUTPUT"]).write_bytes(output)
process.wait()
pathlib.Path(os.environ["KITTY_READY"]).touch()
if os.environ.get("HOLD_TERMINAL"):
    deadline = time.monotonic() + 10
    while not pathlib.Path(os.environ["KITTY_RELEASE"]).exists():
        if time.monotonic() > deadline: sys.exit(99)
        time.sleep(0.02)
""")
    kitty.chmod(0o755)
    calls = root / "calls"
    kitty_calls = root / "kitty-calls"
    output = root / "output"
    ready = root / "ready"
    release = root / "release"
    base_env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "WAYLAND_DISPLAY": "wayland-1", "CALL_LOG": str(calls),
                "KITTY_CALLS": str(kitty_calls), "PTY_OUTPUT": str(output),
                "KITTY_READY": str(ready), "KITTY_RELEASE": str(release)}

    def launch(home, **extra):
        home.mkdir(exist_ok=True)
        return subprocess.run([str(gui)], env={**base_env, "HOME": str(home), **extra},
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    # A graphical launch supplies real tty streams to the same helper and keeps
    # output visible through --hold. Console sudo behavior remains unchanged.
    home = root / "success"
    result = launch(home)
    assert result.returncode == 0, result.stderr
    args = json.loads(kitty_calls.read_text().splitlines()[0])
    assert args == ["--hold", "--title", "Void dotfiles setup", str(helper)], args
    assert calls.read_text().splitlines() == ["init --apply example/dotfiles"]
    assert "completed" in output.read_text()
    assert (home / ".local/state/void-installer/chezmoi.status").read_text().strip() == "complete"
    result = launch(home)
    assert result.returncode == 0 and len(kitty_calls.read_text().splitlines()) == 1

    # Failed and interrupted setups never auto-retry in either entry point.
    failed = root / "failure"
    result = launch(failed, CHEZMOI_RC="1")
    assert result.returncode == 0, result.stderr  # held terminal completed
    assert "--retry" in output.read_text()
    assert (failed / ".local/state/void-installer/chezmoi.status").read_text().strip() == "failed"
    before = len(kitty_calls.read_text().splitlines())
    for status in ("failed", "running", "complete"):
        (failed / ".local/state/void-installer/chezmoi.status").write_text(status + "\n")
        result = launch(failed)
        assert result.returncode == 0 and len(kitty_calls.read_text().splitlines()) == before

    # The helper's main lock also prevents launching while console setup runs.
    locked = root / "locked"
    state_dir = locked / ".local/state/void-installer"
    state_dir.mkdir(parents=True)
    with (state_dir / "chezmoi.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = launch(locked)
        assert result.returncode == 0 and len(kitty_calls.read_text().splitlines()) == before
    # Two simultaneous GUI starts must not open two setup terminals, even when
    # the first helper failed and its terminal stays open displaying the error.
    concurrent = root / "concurrent"
    concurrent.mkdir()
    ready.unlink()
    first = subprocess.Popen([str(gui)], env={**base_env, "HOME": str(concurrent),
                              "CHEZMOI_RC": "1", "HOLD_TERMINAL": "1"},
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        wait_ready(ready, first)
        (concurrent / ".local/state/void-installer/chezmoi.status").unlink()
        before = len(kitty_calls.read_text().splitlines())
        result = launch(concurrent)
        assert result.returncode == 0 and len(kitty_calls.read_text().splitlines()) == before
    finally:
        release.touch()
        stdout, stderr = first.communicate(timeout=5)
    assert first.returncode == 0, stderr
    before = len(kitty_calls.read_text().splitlines())
    result = launch(root / "no-wayland", WAYLAND_DISPLAY="")
    assert result.returncode == 0 and len(kitty_calls.read_text().splitlines()) == before
    config.write_text("USERNAME=someone_else\nREPOSITORY=example/dotfiles\n")
    result = launch(root / "wrong-user")
    assert result.returncode == 0 and len(kitty_calls.read_text().splitlines()) == before

    # Run the real autostart editor; it preserves comments/settings and ownership.
    wayfire = root / f"home/{user}/.config/wayfire.ini"
    wayfire.parent.mkdir(parents=True)
    original = "[core]\nplugins = autostart command\n[autostart]\n# keep this comment\ncustom = my-command\n[input]\nxkb_layout = de\n"
    wayfire.write_text(original)
    code = embedded("CHEZMOI_AUTOSTART_EOF").replace('f"/home/', f'f"{root}/home/')
    for _ in range(2):
        result = subprocess.run(["python3", "-c", code, user], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert result.returncode == 0, result.stderr
    assert wayfire.read_text().count("void_installer_chezmoi =") == 1
    assert "# keep this comment" in wayfire.read_text() and "custom = my-command" in wayfire.read_text()
    assert wayfire.stat().st_uid == os.getuid()
    wayfire.write_text(original.replace("autostart command", "command"))
    result = subprocess.run(["python3", "-c", code, user], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode != 0 and "autostart plugin" in result.stderr, result.stderr

assert "NOPASSWD" not in embedded("CHEZMOI_GUI_EOF")
print("Verified: visible GUI setup, tty streams, shared locking, no duplicate terminals, state gating and preserved autostart config.")
