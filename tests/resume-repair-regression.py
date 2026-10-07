"""Exercise checkpoint validation and prove resume/repair avoid disk creation."""
import pathlib
import subprocess
import tempfile

source = pathlib.Path(__file__).resolve().parents[1] / "install.sh"
text = source.read_text()


def extract(start_marker, end_marker):
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    return text[start:end]


state_reader = extract("read_install_state() {", "identify_existing_devices() {")
resume = extract("run_resume() {", "run_repair() {")
repair_action = extract("run_repair_action() {", "run_resume() {")
repair = extract("run_repair() {", "validate_target_installation() {")

valid_state = """FORMAT=1
VERSION=1.3.10
ROOT_UUID=root-uuid
ESP_UUID=esp-uuid
TARGET_DISK=/dev/vda
LAST_COMPLETED_STEP=12
LAST_COMPLETED_CHECKPOINT=packages-installed
INSTALL_STATUS=active
HOSTNAME=void
USERNAME=fixture
USER_SHELL=/bin/bash
TIMEZONE=UTC
LOCALE=en_US.UTF-8
KEYMAP=us
MIRROR=https://repo-default.voidlinux.org
SWAP=zram
CHEZMOI_MODE=first-login
WIFI_SSID=
WIFI_SECURITY=wpa-psk
WIFI_HIDDEN=no
CHEZMOI_REPO=
EXTRA_PACKAGES=
HW_CHASSIS=auto
HW_TOUCH=auto
HW_FINGERPRINT=auto
HW_BLUETOOTH=auto
"""
with tempfile.TemporaryDirectory(prefix="void-resume-regression-") as directory:
    root = pathlib.Path(directory)
    state_dir = root / "state-dir"
    state_dir.mkdir(mode=0o700)
    state = state_dir / "state"

    def read_result(contents, mode="0600"):
        state.write_text(contents)
        state.chmod(int(mode, 8))
        harness = (
            "#!/bin/bash\nset -eu\nINSTALLER_VERSION=1.3.10\n"
            "INSTALL_STATE_STEP=0\nINSTALL_STATE_CHECKPOINT=none\nINSTALL_STATUS=active\n"
            "stat() { if [[ $1 == -c && $2 == %u ]]; then echo 0; else command stat \"$@\"; fi; }\n"
            + state_reader
            + 'read_install_state "$1"'
        )
        return subprocess.run(
            ["bash", "-c", harness, "test", str(state)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )

    result = read_result(valid_state)
    assert result.returncode == 0, result.stdout
    assert "LAST_COMPLETED_STEP" not in result.stdout
    for contents, mode, message in (
        (valid_state.replace("VERSION=1.3.10", "VERSION=1.3.9"), "0600", "format/version"),
        (valid_state.replace("LAST_COMPLETED_STEP=12", "LAST_COMPLETED_STEP=12\nLAST_COMPLETED_STEP=13"), "0600", "Duplicate"),
        (valid_state.replace("packages-installed", "bootloader-configured"), "0600", "do not match"),
        (valid_state, "0644", "permissions"),
    ):
        result = read_result(contents, mode)
        assert result.returncode != 0 and message in result.stdout, result.stdout

# Run the actual resume dispatcher with harmless functions and a checkpoint at
# 12. It must begin at 13 and never call the formatting/partitioning helpers.
harness = r'''#!/bin/bash
set -eu
INSTALL_STATE_STEP=12
INSTALL_STATE=
INSTALLER_LOG=/dev/null
apply_defaults() { :; }
preflight() { :; }
load_resume_state() { :; }
detect_hardware() { :; }
build_package_lists() { :; }
probe_packages() { :; }
step_repair_partial_packages() { :; }
partition_disk() { echo partition-called >&2; return 90; }
format_disk() { echo format-called >&2; return 91; }
run_step() { printf '%s:%s\n' "$1" "$3"; INSTALL_STATE_STEP=$1; }
bootstrap_prepare() { :; }
bootstrap_install() { :; }
configure_system() { :; }
setup_snapper() { :; }
setup_grub() { :; }
enable_services() { :; }
create_user() { :; }
configure_chezmoi_first_login() { :; }
apply_chezmoi() { :; }
install_wrappers() { :; }
initial_snapshot() { :; }
validate_target_installation() { :; }
finalize() { :; }
'''
harness += resume + "run_resume\n"
result = subprocess.run(["bash"], input=harness, text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert result.returncode == 0, result.stderr
steps = [line.split(":", 1)[0] for line in result.stdout.splitlines()]
assert steps == [str(n) for n in range(13, 24)], result.stdout
assert "partition-called" not in result.stderr and "format-called" not in result.stderr

# The repair action dispatcher invokes its requested action only. The mount
# wrapper itself contains no disk creation operation.
harness = r'''#!/bin/bash
set -eu
REPAIR_ACTION=check
ESP_UUID=fixture-esp
partition_disk() { echo partition-called >&2; return 90; }
format_disk() { echo format-called >&2; return 91; }
validate_target_installation() { echo action-called; }
repair_menu() { :; }
'''
harness += repair_action + "run_repair_action\n"
result = subprocess.run(["bash"], input=harness, text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert result.returncode == 0, result.stderr
assert "action-called" in result.stdout
assert "partition-called" not in result.stderr and "format-called" not in result.stderr
assert "partition_disk" not in repair and "format_disk" not in repair
assert "partition_disk" not in repair_action and "format_disk" not in repair_action
print("Verified: resume rejects unsafe/mismatched state and resumes from the next checkpoint; repair never formats or partitions.")
