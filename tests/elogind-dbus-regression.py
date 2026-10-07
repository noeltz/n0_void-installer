"""Verify elogind uses D-Bus activation by default, without its runit service."""
import pathlib
import re
import subprocess
import tempfile


source = pathlib.Path(__file__).resolve().parents[1] / "install.sh"
text = source.read_text()


def section(start, end):
    return text[text.index(start):text.index(end, text.index(start))]


def run(script):
    return subprocess.run(["bash", "-c", "set -eu\n" + script], text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


pkg_add = section("pkg_add() {", "build_package_lists() {")
probe = section("probe_packages() {", "probe_query() {")
enable = section("enable_sv() {", "create_user() {")
activation_check = section("validate_elogind_activation() {", "run_repair_action() {")
repair = section("run_repair() {", "validate_target_installation() {")
validator = section("validate_target_installation() {", "bootstrap_prepare() {")

assert 'INSTALLER_VERSION="1.3.14"' in text
assert ('if ! probe_query -f elogind | grep -F '
        '"usr/share/dbus-1/system-services/org.freedesktop.login1.service" >/dev/null; then' in probe)
assert "elogind:elogind" not in probe
assert "validate_elogind_activation /mnt" in validator
assert "validate_enabled_services /mnt" in validator

build = section("build_package_lists() {", "# --------------------------------------------------------------------------\n# Package and service probe")
variables = """SWAP=none HW_CPU= HW_GPUS= HW_CHASSIS_RESULT= HW_TOUCH_RESULT=
HW_CONVERTIBLE= HW_FINGERPRINT_RESULT= HW_BLUETOOTH_RESULT= HW_VM= HW_VM_TYPE=
EXTRA_PACKAGES= PKGS_ALL=() SV_FATAL=() SV_OPTIONAL=()
declare -A PKG_SEEN=()
"""
list_result = run(pkg_add + build + variables + "build_package_lists\nprintf 'PACKAGES=%s\\nFATAL=%s\\n' \"${PKGS_ALL[*]}\" \"${SV_FATAL[*]}\"\n")
assert list_result.returncode == 0, list_result.stderr
packages, fatal = list_result.stdout.strip().splitlines()
packages = packages.removeprefix("PACKAGES=").split()
fatal = fatal.removeprefix("FATAL=").split()
assert "elogind" in packages
assert "dbus" in fatal and "elogind" not in fatal

repair_assignment = re.search(r"^\s*SV_FATAL=\(([^)]*)\)", repair, re.M)
assert repair_assignment, "repair mode must set its required service list"
repair_services = repair_assignment.group(1).split()
assert "dbus" in repair_services and "elogind" not in repair_services

# Exercise the fresh-install service loop with an isolated fake target.
with tempfile.TemporaryDirectory(prefix="void-elogind-dbus-regression-") as directory:
    root = pathlib.Path(directory)
    for service in fatal:
        (root / "etc/sv" / service).mkdir(parents=True)
    default = root / "etc/runit/runsvdir/default"
    default.mkdir(parents=True)
    isolated_enable = enable.replace("/mnt", str(root))
    install_result = run(
        pkg_add + build + variables + isolated_enable
        + "build_package_lists\nGRUB_BTRFS_OWN=0 NETWORKMANAGER_OWN=0\n"
        + "enable_services\n"
    )
    assert install_result.returncode == 0, install_result.stderr
    assert (default / "dbus").is_symlink()
    assert not (default / "elogind").exists()

    # Final and repair validation require the D-Bus activation file and only
    # services from SV_FATAL; dbus is required while elogind's runit link is not.
    service_links = section("validate_enabled_services() {", "run_repair_action() {")
    activation_path = root / "usr/share/dbus-1/system-services/org.freedesktop.login1.service"
    # Re-run with the temporary root as the first bash positional argument.
    check_services = subprocess.run(
        ["bash", "-c", "set -eu\n" + pkg_add + build + variables + service_links
         + "build_package_lists\nvalidate_enabled_services \"$1\"\n", "test", str(root)],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert check_services.returncode == 0, check_services.stderr
    (default / "dbus").unlink()
    check_services = subprocess.run(
        ["bash", "-c", "set -eu\n" + pkg_add + build + variables + service_links
         + "build_package_lists\nvalidate_enabled_services \"$1\"\n", "test", str(root)],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert check_services.returncode != 0 and "dbus" in check_services.stderr

    check_activation = activation_check + "validate_elogind_activation \"$1\"\n"
    result = subprocess.run(["bash", "-c", "set -eu\n" + check_activation,
                            "test", str(root)], text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode != 0 and "activation file" in result.stderr
    activation_path.parent.mkdir(parents=True)
    activation_path.write_text("[D-BUS Service]\nName=org.freedesktop.login1\n")
    result = subprocess.run(["bash", "-c", "set -eu\n" + check_activation,
                             "test", str(root)], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode == 0, result.stderr

print("Verified: elogind package and activation file are required; dbus is enabled while elogind's runit service is not.")
