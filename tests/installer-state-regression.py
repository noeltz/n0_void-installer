"""Check config diagnostics, checkpoint state, and logged output for secrets."""
import pathlib
import subprocess
import tempfile

source = pathlib.Path(__file__).resolve().parents[1] / "install.sh"
text = source.read_text()


def extract(start_marker, end_marker):
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    return text[start:end]


load_config = extract("load_config() {", "apply_defaults() {")
write_state = extract("write_install_state() {", "initialize_install_state() {")
run_step = extract("run_step() {", "load_settings() {")

with tempfile.TemporaryDirectory(prefix="void-state-regression-") as directory:
    root = pathlib.Path(directory)
    config = root / "bad.conf"
    config.write_text("this malformed line contains config-secret\n")
    result = subprocess.run(
        ["bash", "-c", load_config + 'CONFIG_SET=" "; load_config "$1"', "test", str(config)],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert "config-secret" not in result.stdout, result.stdout
    assert "line 1" in result.stdout, result.stdout

    state = root / "state"
    harness = """#!/bin/bash
set -eu
INSTALL_STATE=$1
INSTALLER_VERSION=1.3.5
ROOT_UUID=root-fixture
ESP_UUID=esp-fixture
TARGET_DISK=/dev/vda
INSTALL_STATE_STEP=10
HOSTNAME=void
USERNAME=fixture
USER_SHELL=/bin/bash
TIMEZONE=UTC
LOCALE=en_US.UTF-8
KEYMAP=us
MIRROR=https://repo-default.voidlinux.org
SWAP=zram
CHEZMOI_MODE=first-login
CHEZMOI_REPO=example/dotfiles
EXTRA_PACKAGES=
HW_CHASSIS=auto
HW_TOUCH=auto
HW_FINGERPRINT=auto
HW_BLUETOOTH=auto
USER_PASSWORD=user-secret
USER_PASSWORD_HASH='$6$user-hash-secret'
ROOT_PASSWORD=root-secret
ROOT_PASSWORD_HASH='$6$root-hash-secret'
""" + write_state + "write_install_state\n"
    subprocess.run(["bash", "-c", harness, "test", str(state)], check=True)
    contents = state.read_text()
    for secret in ("user-secret", "user-hash-secret", "root-secret", "root-hash-secret"):
        assert secret not in contents, contents
    assert "LAST_COMPLETED_STEP=10" in contents
    assert "FORMAT=1" in contents

    log = root / "install.log"
    step_harness = (
        "#!/bin/bash\nset -eu\nINSTALLER_LOG=$1\nCURRENT_STEP_N=14\n"
        "INSTALL_STATE=\nINSTALL_STATE_STEP=0\n"
        + run_step
        + "run_step 14 'Apply chezmoi dotfiles' printf '%s\\n' dotfile-output-secret\n"
    )
    subprocess.run(["bash", "-c", step_harness, "test", str(log)], check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert "dotfile-output-secret" not in log.read_text()

print("Verified: config diagnostics, checkpoint state, and dotfile output exclude secrets.")
