"""Exercise generated desktop config, keyboard conversion, preservation and checks."""
import configparser
import os
import pathlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET

source = pathlib.Path(__file__).resolve().parents[1] / "install.sh"
text = source.read_text()
derive = text[text.index("derive_desktop_keymap() {"):text.index("validate_one() {")]
configure = text[text.index("write_desktop_user_file() {"):text.index("configure_greetd() {")]
validator = text.split("<<'DESKTOP_CHECK_EOF'\n", 1)[1].split("\nDESKTOP_CHECK_EOF", 1)[0]


def run(script, *args):
    return subprocess.run(["bash", "-c", "set -eu\n" + script, "test", *map(str, args)],
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


maps = {
    "us": ("us", "", "pc105"), "uk": ("gb", "", "pc105"),
    "de": ("de", "", "pc105"), "de-latin1-nodeadkeys": ("de", "nodeadkeys", "pc105"),
    "de_CH-latin1": ("ch", "", "pc105"), "fr_CH-latin1": ("ch", "fr", "pc105"),
    "fr-latin9": ("fr", "latin9", "pc105"), "fr-bepo": ("fr", "bepo", "pc105"),
    "br-abnt2": ("br", "", "abnt2"), "dvorak": ("us", "dvorak", "pc105"),
    "dvorak-programmer": ("us", "dvp", "pc105"), "dvorak-l": ("us", "dvorak-l", "pc105"),
    "dvorak-r": ("us", "dvorak-r", "pc105"), "cz-qwerty": ("cz", "qwerty", "pc105"),
    "sk-qwerty": ("sk", "qwerty", "pc105"), "es": ("es", "", "pc105"),
    "it": ("it", "", "pc105"), "pt": ("pt", "", "pc105"), "be-latin1": ("be", "", "pc105"),
    "dk": ("dk", "", "pc105"), "fi": ("fi", "", "pc105"), "no": ("no", "", "pc105"),
    "sv-latin1": ("se", "", "pc105"), "pl2": ("pl", "", "pc105"), "hu": ("hu", "", "pc105"),
}
for name, expected in maps.items():
    for suffix in ("", ".map", ".map.gz"):
        result = run(derive + 'derive_desktop_keymap "$1"\nprintf "%s|%s|%s" "$XKB_LAYOUT" "$XKB_VARIANT" "$XKB_MODEL"', name + suffix)
        assert result.returncode == 0 and tuple(result.stdout.split("|")) == expected, result
for name in ("custom", "/tmp/us.map", "../../us", ""):
    result = run(derive + 'derive_desktop_keymap "$1"', name)
    assert result.returncode != 0, name

with tempfile.TemporaryDirectory(prefix="void-desktop-regression-") as directory:
    root = pathlib.Path(directory)
    config = root / "home/fixture/.config"
    config.mkdir(parents=True)
    script = derive + configure + '\nUSERNAME=fixture\nKEYMAP=de-latin1-nodeadkeys\nchroot() { :; }\nconfigure_greetd() { :; }\nconfigure_desktop "$1"\n'
    result = run(script, root)
    assert result.returncode == 0, result.stderr
    wayfire = config / "wayfire.ini"
    panel = config / "wf-shell.ini"
    ini = configparser.ConfigParser(interpolation=None)
    ini.read(wayfire)
    assert ini["input"]["xkb_layout"] == "de"
    assert ini["input"]["xkb_variant"] == "nodeadkeys"
    assert ini["autostart"]["autostart_wf_shell"] == "true"
    assert ini["command"]["command_terminal"] == "kitty"
    assert ini["command"]["command_logout"] == "wayland-logout"
    ini.read(panel)
    assert ini["panel"]["launcher_terminal"] == "kitty.desktop"
    assert "volume" not in ini["panel"]["widgets_right"]
    assert wayfire.stat().st_mode & 0o777 == 0o644

    # A rerun preserves user settings and never follows a file/directory symlink.
    wayfire.write_text("[input]\nxkb_layout=fr\n# custom settings\n")
    result = run(script, root)
    assert result.returncode == 0 and "custom settings" in wayfire.read_text(), result.stderr
    wayfire.unlink()
    outside = root / "outside"
    outside.write_text("keep-me")
    wayfire.symlink_to(outside)
    result = run(script, root)
    assert result.returncode != 0 and outside.read_text() == "keep-me", result.stdout
    wayfire.unlink()
    result = run(script, root)
    assert result.returncode == 0, result.stderr

    # Run the actual embedded validator against a fixture XKB registry and native
    # session. The target paths and account database alone are adapted for isolation.
    rules = root / "usr/share/X11/xkb/rules"
    rules.mkdir(parents=True)
    registry = ET.Element("xkbConfigRegistry")
    models = ET.SubElement(registry, "modelList")
    ET.SubElement(ET.SubElement(ET.SubElement(models, "model"), "configItem"), "name").text = "pc105"
    layouts = ET.SubElement(registry, "layoutList")
    layout = ET.SubElement(layouts, "layout")
    ET.SubElement(ET.SubElement(layout, "configItem"), "name").text = "de"
    variants = ET.SubElement(layout, "variantList")
    ET.SubElement(ET.SubElement(ET.SubElement(variants, "variant"), "configItem"), "name").text = "nodeadkeys"
    ET.ElementTree(registry).write(rules / "evdev.xml")
    session = root / "usr/share/wayland-sessions/wayfire.desktop"
    session.parent.mkdir(parents=True)
    session.write_text("[Desktop Entry]\nExec=wayfire\nName=Wayfire\nType=Application\n")
    isolated = validator.replace('"/usr/', f'"{root}/usr/').replace('"/etc/', f'"{root}/etc/').replace('f"/home/', f'f"{root}/home/')
    isolated = isolated.replace(f'!= "{root}/usr/local/sbin/void-installer-chezmoi-gui"',
                                '!= "/usr/local/sbin/void-installer-chezmoi-gui"')
    isolated = isolated.replace("pwd.getpwnam(user).pw_uid", str(os.getuid()))
    for variant, code in (("nodeadkeys", 0), ("nonexistent", 1)):
        result = subprocess.run(["python3", "-c", isolated, "fixture", "de", variant, "pc105"],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert result.returncode == code, result.stderr
    session.unlink()
    result = subprocess.run(["python3", "-c", isolated, "fixture", "de", "nodeadkeys", "pc105"],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode != 0 and "session" in result.stderr, result.stderr

    session.write_text("[Desktop Entry]\nExec=wayfire\n")
    helpers = root / "usr/local/sbin"
    helpers.mkdir(parents=True)
    for name in ("void-installer-chezmoi", "void-installer-chezmoi-gui"):
        path = helpers / name
        path.write_text("#!/bin/bash\nexit 0\n")
        path.chmod(0o755)
    setup = root / "etc/void-installer/chezmoi.conf"
    setup.write_text("USERNAME=fixture\nREPOSITORY=example/dotfiles\n")
    isolated = isolated.replace("os.stat(path).st_uid != 0", f"os.stat(path).st_uid != {os.getuid()}")

    def check_gui():
        return subprocess.run(["python3", "-c", isolated, "fixture", "de", "nodeadkeys", "pc105"],
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    result = check_gui()
    assert result.returncode != 0 and "first-login setup hook" in result.stderr, result.stderr
    ini = configparser.ConfigParser(interpolation=None)
    ini.read(wayfire)
    ini.set("autostart", "void_installer_chezmoi", "/usr/local/sbin/void-installer-chezmoi-gui")
    with wayfire.open("w") as file:
        ini.write(file)
    result = check_gui()
    assert result.returncode == 0, result.stderr
    setup.write_text("USERNAME=wrong-user\nREPOSITORY=example/dotfiles\n")
    result = check_gui()
    assert result.returncode != 0 and "does not match" in result.stderr, result.stderr

# On Void, also check every conversion against its real registry. Ubuntu CI
# uses a different XKB release (without Void's ABNT2 model); the installed
# target's registry is always checked by the installer regardless of host OS.
registry_path = pathlib.Path("/usr/share/X11/xkb/rules/evdev.xml")
os_release = pathlib.Path("/etc/os-release")
is_void = os_release.exists() and "ID=void" in os_release.read_text().splitlines()
if is_void and registry_path.exists():
    registry = ET.parse(registry_path).getroot()
    layouts = {item.findtext("configItem/name"): item for item in registry.findall("layoutList/layout")}
    models = {item.findtext("configItem/name") for item in registry.findall("modelList/model")}
    for layout, variant, model in maps.values():
        assert layout in layouts and model in models, (layout, model)
        assert not variant or variant in {item.findtext("configItem/name")
               for item in layouts[layout].findall("variantList/variant")}, (layout, variant)

print("Verified: desktop keyboard conversion, usable baseline, preservation, symlink rejection and final validation.")
