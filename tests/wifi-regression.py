"""Test target NetworkManager keyfile output, permissions, escaping, and limits."""
import pathlib
import stat
import subprocess
import tempfile

source = pathlib.Path(__file__).resolve().parents[1] / "install.sh"
text = source.read_text()


def extract(start_marker, end_marker):
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    return text[start:end]


profile_functions = extract("escape_nm_keyfile_value() {", "# --------------------------------------------------------------------------\n# snapper / GRUB")
validation = extract("validate_one() {", "# Normalise a locale name")

with tempfile.TemporaryDirectory(prefix="void-wifi-regression-") as directory:
    root = pathlib.Path(directory)
    target = root / "target"
    harness = (
        "#!/bin/bash\nset -eu\n"
        "chown() { :; }\n"
        f"WIFI_SSID=$2\nWIFI_SECURITY=$3\nWIFI_HIDDEN=$4\n"
        "if [[ $5 == __UNSET__ ]]; then unset WIFI_PASSWORD; else WIFI_PASSWORD=$5; fi\n"
        + profile_functions + "write_wifi_profile \"$1\"\n"
    )
    ssid = " Café "
    password = "  pass;#\\word  "
    subprocess.run(["bash", "-c", harness, "test", str(target), ssid,
                    "wpa-psk", "yes", password], check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    profile = target / "etc/NetworkManager/system-connections/installer-wifi.nmconnection"
    contents = profile.read_text()
    assert "ssid=\\sCafé\\s\n" in contents, contents
    assert "hidden=true\n" in contents, contents
    assert "key-mgmt=wpa-psk\n" in contents, contents
    assert "psk=\\s pass;#\\\\word \\s\n" in contents, contents
    assert stat.S_IMODE(profile.stat().st_mode) == 0o600
    assert stat.S_IMODE(profile.parent.stat().st_mode) == 0o700
    if subprocess.run(["sh", "-c", "command -v nmcli >/dev/null 2>&1"]).returncode == 0:
        subprocess.run(["nmcli", "--offline", "connection", "modify", "type", "wifi"],
                       input=contents, text=True, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    open_target = root / "open-target"
    subprocess.run(["bash", "-c", harness, "test", str(open_target), "Cafe",
                    "open", "no", "__UNSET__"], check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    open_profile = open_target / "etc/NetworkManager/system-connections/installer-wifi.nmconnection"
    open_contents = open_profile.read_text()
    assert "ssid=Cafe\n" in open_contents and "method=auto" in open_contents
    assert "wifi-security" not in open_contents and "psk=" not in open_contents
    if subprocess.run(["sh", "-c", "command -v nmcli >/dev/null 2>&1"]).returncode == 0:
        subprocess.run(["nmcli", "--offline", "connection", "modify", "type", "wifi"],
                       input=open_contents, text=True, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    empty_target = root / "empty-target"
    subprocess.run(["bash", "-c", harness, "test", str(empty_target), "",
                    "open", "no", "__UNSET__"], check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert not empty_target.exists()

    def validity(key, value):
        script = validation + 'if validate_one "$1" "$2"; then echo valid; else echo invalid; fi\n'
        result = subprocess.run(["bash", "-c", script, "test", key, value], check=True,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return result.stdout.strip()

    assert validity("WIFI_SSID", "x" * 32) == "valid"
    assert validity("WIFI_SSID", "x" * 33) == "invalid"
    assert validity("WIFI_SSID", "bad\nssid") == "invalid"
    assert validity("WIFI_PASSWORD", "x" * 7) == "invalid"
    assert validity("WIFI_PASSWORD", "x" * 8) == "valid"
    assert validity("WIFI_PASSWORD", "a" * 64) == "valid"
    assert validity("WIFI_PASSWORD", "g" * 64) == "invalid"

print("Verified: Wi-Fi profile modes, keyfile escaping/permissions, and credential validation.")
