"""Run the embedded greetd configurator/checker against an isolated target."""
import os
import pathlib
import subprocess
import tempfile
import tomllib

text = (pathlib.Path(__file__).resolve().parents[1] / "install.sh").read_text()


def embedded(tag):
    return text.split("<<'" + tag + "'\n", 1)[1].split("\n" + tag, 1)[0]


with tempfile.TemporaryDirectory(prefix="void-greetd-regression-") as directory:
    root = pathlib.Path(directory)
    config = root / "etc/greetd/config.toml"
    config.parent.mkdir(parents=True)
    (root / "etc/void-installer").mkdir()
    (root / "var/cache").mkdir(parents=True)
    default = root / "etc/runit/runsvdir/default"
    default.mkdir(parents=True)
    for service in ("agetty-tty1", "agetty-tty7", "greetd"):
        dest = root / "etc/sv" / service
        dest.mkdir(parents=True)
        (dest / "run").write_text("#!/bin/sh\nexit 0\n")
        (dest / "run").chmod(0o755)
        (default / service).symlink_to(dest)
    for name in ("greetd", "tuigreet"):
        path = root / "usr/bin" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
    pam = root / "etc/pam.d/greetd"
    pam.parent.mkdir()
    pam.write_text("auth include system-local-login\n")
    original = '''# retain packaged comments
[terminal]
vt = 1
switch = true
[default_session]
command = "agreety --cmd /bin/sh"
user = "fixture_greeter" # preserve account
[general]
source_profile = true
'''
    config.write_text(original)

    def run(tag):
        code = embedded(tag).replace('"/etc/', f'"{root}/etc/').replace('"/var/', f'"{root}/var/').replace('"/usr/', f'"{root}/usr/')
        # Only the system account database and privileged ownership call are
        # substituted. All config parsing, filesystem checks and writes are real.
        code = code.replace("account = pwd.getpwnam(greeter)", f"account = type('Account', (), {{'pw_uid': {os.getuid()}, 'pw_gid': {os.getgid()}}})()")
        code = code.replace('account = pwd.getpwnam(session["user"])', f"account = type('Account', (), {{'pw_uid': {os.getuid()}, 'pw_gid': {os.getgid()}}})()")
        code = code.replace("os.chown(cache, account.pw_uid, account.pw_gid)", "assert account.pw_uid != 0")
        return subprocess.run(["python3", "-c", code], text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    result = run("GREETD_CONFIG_EOF")
    assert result.returncode == 0, result.stderr
    parsed = tomllib.loads(config.read_text())
    assert parsed["terminal"] == {"vt": 7, "switch": True}
    assert parsed["default_session"]["user"] == "fixture_greeter"
    assert "--remember-session" in parsed["default_session"]["command"]
    assert "--session-wrapper 'dbus-run-session --'" in parsed["default_session"]["command"]
    assert parsed["general"]["source_profile"] is True
    assert "retain packaged comments" in config.read_text()
    assert (default / "agetty-tty1").is_symlink()
    assert not (default / "agetty-tty7").is_symlink()
    assert config.stat().st_mode & 0o777 == 0o644
    saved = config.read_text()
    result = run("GREETD_CONFIG_EOF")
    assert result.returncode == 0 and config.read_text() == saved, result.stderr
    result = run("GREETD_CHECK_EOF")
    assert result.returncode == 0, result.stderr
    cache = root / "var/cache/tuigreet"
    cache.chmod(0o700)
    result = run("GREETD_CHECK_EOF")
    assert result.returncode != 0 and "permissions" in result.stderr, result.stderr
    cache.chmod(0o755)
    (default / "agetty-tty7").symlink_to(root / "etc/sv/agetty-tty7")
    result = run("GREETD_CHECK_EOF")
    assert result.returncode != 0 and "conflicts" in result.stderr, result.stderr
    (default / "agetty-tty7").unlink()
    (default / "agetty-tty7").mkdir()
    result = run("GREETD_CONFIG_EOF")
    assert result.returncode != 0 and "unexpected service" in result.stderr, result.stderr
    assert config.read_text() == saved
    (default / "agetty-tty7").rmdir()
    (default / "agetty-tty1").unlink()
    result = run("GREETD_CONFIG_EOF")
    assert result.returncode != 0 and "recovery console" in result.stderr, result.stderr
    (default / "agetty-tty1").symlink_to(root / "etc/sv/agetty-tty1")
    config.write_text(original.replace('user = "fixture_greeter" # preserve account', "# missing packaged account"))
    result = run("GREETD_CONFIG_EOF")
    assert result.returncode != 0 and "no greeter account" in result.stderr, result.stderr
    config.write_text(saved.replace("dbus-run-session --", "wrong-wrapper"))
    result = run("GREETD_CHECK_EOF")
    assert result.returncode != 0 and "session wrapper" in result.stderr, result.stderr
    config.unlink()
    outside = root / "outside"
    outside.write_text("preserve")
    config.symlink_to(outside)
    result = run("GREETD_CONFIG_EOF")
    assert result.returncode != 0 and "destination" in result.stderr, result.stderr
    assert outside.read_text() == "preserve"

print("Verified: greetd TOML preservation, tty7 isolation, tty1 recovery, cache permissions, retry and final checks.")
