"""Verify cleanup only unmounts exact mounts owned by this installer."""
import pathlib
import os
import subprocess
import tempfile

source = pathlib.Path(__file__).resolve().parents[1] / "install.sh"
text = source.read_text()
start = text.index("mount_owned() {")
end = text.index("partition_disk() {", start)
functions = text[start:end]

harness = r'''#!/bin/bash
set -eu
declare -a INSTALL_MOUNTS=()
mounts=(
  "/mnt|/dev/vda2[/@]|btrfs"
  "/mnt/home|/dev/vda2[/@home]|btrfs"
  "/mnt/changed|/dev/other|ext4"
  "/mnt/unrelated|/dev/other|ext4"
)
unmounted=()
findmnt() {
  if [[ $* == "-rn -o TARGET" ]]; then
    printf '%s\n' "${mounts[@]}" | cut -d'|' -f1
    return
  fi
  printf '%s\n' \
    "/mnt /dev/vda2[/@] btrfs" \
    "/mnt/home /dev/vda2[/@home] btrfs" \
    "/mnt/changed /dev/other ext4" \
    "/mnt/unrelated /dev/other ext4"
}
umount() {
  unmounted+=("$1")
}
'''
harness += functions
harness += r'''
INSTALL_MOUNTS=(
  "/mnt|/dev/vda2[/@]|btrfs"
  "/mnt/home|/dev/vda2[/@home]|btrfs"
  "/mnt/stale|/dev/vda2[/@stale]|btrfs"
  "/mnt/changed|/dev/vda2[/@changed]|btrfs"
)
unmount_owned
printf 'UNMOUNTED:%s\n' "${unmounted[*]}"
printf 'REMAINING:%s\n' "${INSTALL_MOUNTS[*]}"
'''

result = subprocess.run(["bash"], input=harness, text=True, check=True,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert "UNMOUNTED:/mnt/home /mnt" in result.stdout, result.stdout
assert "/mnt/changed|/dev/vda2[/@changed]|btrfs" in result.stdout, result.stdout
assert "/mnt/stale|" not in result.stdout, result.stdout
assert "/mnt/unrelated" not in result.stdout, result.stdout
print("Verified: cleanup unmounts only matching owned mounts in reverse order.")

with tempfile.TemporaryDirectory(prefix="void-cleanup-regression-") as directory:
    temp = pathlib.Path(directory)
    marker = temp / "umount-called"
    fake_umount = temp / "umount"
    fake_umount.write_text(f"#!/bin/sh\nprintf called > {marker}\n")
    fake_umount.chmod(0o755)
    env = {**os.environ, "PATH": f"{temp}:{os.environ['PATH']}"}
    for args in (("--help",), ("--invalid-option",)):
        subprocess.run(["bash", str(source), *args], env=env, check=False,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert not marker.exists(), "Early exit attempted to unmount /mnt."
print("Verified: help and argument errors do not unmount the existing /mnt tree.")
