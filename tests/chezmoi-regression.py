"""Test generated first-login chezmoi helper gating, retries, and locking."""
import fcntl
import os
import pathlib
import pwd
import pty
import subprocess
import tempfile
import errno

source = pathlib.Path(__file__).resolve().parents[1] / "install.sh"
text = source.read_text()
marker = "cat > \"$helper\" <<'CHEZMOI_EOF'\n"
start = text.index(marker) + len(marker)
end = text.index("\nCHEZMOI_EOF", start)
helper_template = text[start:end]
configure = text[text.index("configure_chezmoi_first_login() {"):text.index("# --------------------------------------------------------------------------\n# xbps snapshot wrappers", text.index("configure_chezmoi_first_login() {"))]


def run_tty(command, env):
    master, slave = pty.openpty()
    process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                               env=env, close_fds=True)
    os.close(slave)
    output = bytearray()
    while True:
        try:
            chunk = os.read(master, 4096)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        output.extend(chunk)
    os.close(master)
    return process.wait(), output.decode(errors="replace")


with tempfile.TemporaryDirectory(prefix="void-chezmoi-regression-") as directory:
    root = pathlib.Path(directory)
    config = root / "chezmoi.conf"
    config.write_text(f"USERNAME={pwd.getpwuid(os.getuid()).pw_name}\nREPOSITORY=example/dotfiles\n")
    helper = root / "void-installer-chezmoi"
    helper.write_text(helper_template.replace("/etc/void-installer/chezmoi.conf", str(config)))
    helper.chmod(0o755)

    target = root / "target"
    (target / "home" / pwd.getpwuid(os.getuid()).pw_name).mkdir(parents=True)
    config_harness = (
        "#!/bin/bash\nset -eu\n"
        f"USERNAME={pwd.getpwuid(os.getuid()).pw_name}\n"
        "CHEZMOI_REPO=example/dotfiles\nCHEZMOI_MODE=first-login\n"
        "chroot() { return 0; }\n" + configure
        + f"configure_chezmoi_first_login {target}\nconfigure_chezmoi_first_login {target}\n"
    )
    subprocess.run(["bash", "-c", config_harness], check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    profile = target / "home" / pwd.getpwuid(os.getuid()).pw_name / ".bash_profile"
    assert profile.read_text().count("# void-installer chezmoi first-login hook") == 1
    configured_helper = target / "usr/local/sbin/void-installer-chezmoi"
    assert configured_helper.stat().st_mode & 0o111
    configured_gui = target / "usr/local/sbin/void-installer-chezmoi-gui"
    assert configured_gui.stat().st_mode & 0o111
    assert not (target / "etc/sudoers.d/99-installer").exists()

    for suffix, repo, mode in (("no-repo", "", "first-login"), ("install", "example/dotfiles", "install")):
        skipped_target = root / suffix
        script = config_harness.split(f"configure_chezmoi_first_login {target}")[0]
        script += f"\nCHEZMOI_REPO='{repo}'\nCHEZMOI_MODE={mode}\nconfigure_chezmoi_first_login {skipped_target}\n"
        subprocess.run(["bash", "-c", script], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert not skipped_target.exists(), skipped_target

    bin_dir = root / "bin"
    bin_dir.mkdir()
    calls = root / "chezmoi-calls"
    fake_chezmoi = bin_dir / "chezmoi"
    fake_chezmoi.write_text(
        "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$CALL_LOG\"\n"
        "if [[ $1 == init ]]; then mkdir -p \"$HOME/.local/share/chezmoi\"; fi\n"
        "exit \"${CHEZMOI_RC:-0}\"\n"
    )
    fake_chezmoi.chmod(0o755)

    home = root / "success-home"
    home.mkdir()
    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
           "HOME": str(home), "CALL_LOG": str(calls)}
    status, output = run_tty([str(helper)], env)
    assert status == 0, output
    assert calls.read_text().splitlines() == ["init --apply example/dotfiles"]
    assert (home / ".local/state/void-installer/chezmoi.status").read_text().strip() == "complete"
    status, output = run_tty([str(helper)], env)
    assert status == 0, output
    assert len(calls.read_text().splitlines()) == 1, calls.read_text()

    failed_home = root / "failed-home"
    failed_home.mkdir()
    failed_env = {**env, "HOME": str(failed_home), "CHEZMOI_RC": "1"}
    status, _ = run_tty([str(helper)], failed_env)
    assert status != 0
    assert (failed_home / ".local/state/void-installer/chezmoi.status").read_text().strip() == "failed"
    before = len(calls.read_text().splitlines())
    status, output = run_tty([str(helper)], failed_env)
    assert status != 0 and "--retry" in output, output
    assert len(calls.read_text().splitlines()) == before
    status, output = run_tty([str(helper), "--retry"], {**failed_env, "CHEZMOI_RC": "0"})
    assert status == 0, output
    assert calls.read_text().splitlines()[-1] == "apply"

    lock_home = root / "locked-home"
    lock_home.mkdir()
    lock_path = lock_home / ".local/state/void-installer/chezmoi.lock"
    lock_path.parent.mkdir(parents=True)
    lock_path.touch()
    with lock_path.open("r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        status, output = run_tty([str(helper)], {**env, "HOME": str(lock_home)})
        assert status != 0 and "already running" in output, output
        fcntl.flock(lock, fcntl.LOCK_UN)

    no_tty = subprocess.run([str(helper)], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert no_tty.returncode != 0 and "interactive terminal" in no_tty.stdout

assert "NOPASSWD" not in helper_template
print("Verified: first-login chezmoi gates, completion, retry, concurrency, and tty behavior.")
