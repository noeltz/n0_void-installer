"""Check Secure Boot detection and GRUB fallback installation behavior."""
import pathlib
import subprocess
import tempfile

source = pathlib.Path(__file__).resolve().parents[1] / "install.sh"
text = source.read_text()


def extract(start_marker, end_marker):
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    return text[start:end]


secure_boot = extract("secure_boot_status() {", "# --------------------------------------------------------------------------\n# Hardware detection")
grub_boot = extract("install_grub_bootloaders() {", "enable_sv() {")

with tempfile.TemporaryDirectory(prefix="void-boot-regression-") as directory:
    root = pathlib.Path(directory)
    efivars = root / "efivars"
    efivars.mkdir()
    variable = efivars / "SecureBoot-fixture"
    for value, expected in ((0, "disabled"), (1, "enabled")):
        variable.write_bytes(bytes((7, 0, 0, 0, value)))
        result = subprocess.run(["bash", "-c", secure_boot + 'secure_boot_status "$1"',
                                 "test", str(efivars)], text=True, check=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert result.stdout.strip() == expected, result.stdout
    variable.unlink()
    result = subprocess.run(["bash", "-c", secure_boot + 'secure_boot_status "$1"',
                             "test", str(efivars)], text=True, check=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.stdout.strip() == "unknown", result.stdout

    for named_rc in (0, 42):
        calls = root / f"grub-calls-{named_rc}"
        harness = (
            "#!/bin/bash\nset -eu\nLOG=$1\nNAMED_RC=$2\n"
            "chroot() { printf '%s\\n' \"$*\" >> \"$LOG\"; "
            "[[ $* == *--bootloader-id=Void* ]] && return \"$NAMED_RC\"; return 0; }\n"
            + grub_boot + "install_grub_bootloaders\n"
        )
        subprocess.run(["bash", "-c", harness, "test", str(calls), str(named_rc)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        commands = calls.read_text().splitlines()
        assert len(commands) == 2, commands
        assert "--bootloader-id=Void" in commands[0], commands
        assert "--removable" in commands[1] and "--no-nvram" in commands[1], commands

print("Verified: Secure Boot state detection and unconditional EFI fallback installation.")
