# Probe & Bootstrap Hardening Plan

## Goal
Replace step 7's RAM-backed dry-run with lightweight package-availability checks, move full dependency + disk-space validation to step 11 against the disk-backed `/mnt`, make bootstrap I/O explicitly disk-backed, and replace unconditional `swapoff -a` with targeted swap handling.

---

## Changes to `install.sh`

### 1. `probe_packages()` — lightweight probe (step 7)
**Current:** Creates temp dir, runs `xbps-install -M -n -y -S -r "$probe" ...` (fails on tmpfs capacity).
**New:**
- Single batched `xbps-query -R -M --repository="$MIRROR/current" --repository="$MIRROR/current/nonfree" "${PKGS_ALL[@]}"` — exits non-zero if any package missing/renamed; stderr names them.
- Keep existing service-file checks (already lightweight: `xbps-query -R -M -f "$pkg" | grep -q "etc/sv/$svc"`).
- Remove `mktemp -d`, key copy, and the dry-run install entirely.
- Error message unchanged: "Package check failed (a package may be missing or renamed). See output above." → exit 3.

### 2. `bootstrap_prepare()` — full validation against `/mnt` (step 11)
**Current:** Only copies keys.
**New:** After key copy, run a full dry-run against the mounted target:
```bash
XBPS_ARCH=x86_64 xbps-install -n -y -S -r /mnt \
  --cachedir /mnt/var/cache/xbps \
  -R "$MIRROR/current" -R "$MIRROR/current/nonfree" \
  "${PKGS_ALL[@]}"
```
- Flags: `-n` (dry-run), `-S` (sync), NO `-M` (let it persist repodata to `/mnt/var/db/xbps` — same as real install).
- `--cachedir` explicit → disk-backed `@var_cache_xbps` subvolume.
- On failure: print "Dependency/disk-space validation against /mnt failed. See output above." → exit 1 (disk already wiped; exit 3 no longer accurate).
- Success: falls through to step 12.

### 3. `bootstrap_install()` — explicit disk-backed I/O (step 12)
**Current:** `xbps-install -S -y -r /mnt ...` (relies on defaults).
**New:** Export `TMPDIR=/mnt/var/tmp` and pass `--cachedir /mnt/var/cache/xbps`:
```bash
TMPDIR=/mnt/var/tmp \
XBPS_ARCH=x86_64 xbps-install -S -y -r /mnt \
  --cachedir /mnt/var/cache/xbps \
  -R "$MIRROR/current" -R "$MIRROR/current/nonfree" \
  "${PKGS_ALL[@]}"
```
- `TMPDIR` ensures any xbps temp files (e.g., signature staging) land on `@var_tmp` subvolume.
- `--cachedir` explicit (harmless if default already points there; guarantees intent).
- Both directories already created & mounted by `mount_layout()` (@var_cache_xbps, @var_tmp).

### 4. `partition_disk()` — targeted swapoff (step 9)
**Current:** `swapoff -a` (kills all swap, including unrelated disks & zram).
**New:** Deactivate only swaps whose device path is a partition of `TARGET_DISK`:
```bash
# Deactivate only swap on the target disk; swap on other disks (and zram)
# stays active — swapoff -a would take down unrelated system swap.
local swdev
while IFS= read -r swdev; do
  case $swdev in
    "$TARGET_DISK"[0-9]*|"$TARGET_DISK"p[0-9]*)
      swapoff "$swdev" || true ;;
  esac
done < <(awk 'NR>1{print $1}' /proc/swaps)
```
- Patterns cover: `/dev/sdaN`, `/dev/nvme0n1pN`, `/dev/mmcblk0pN`, `/dev/vdN`.
- False-positive guard: requires digit immediately after prefix (`/dev/sdaa3` → `a` not digit → no match).
- `|| true` silences error on already-inactive swap; wipefs will fail clearly if still busy.
- zram (`/dev/zram0`) and other-disk swaps untouched.

### 5. Optional: temporary disk-backed swap
**Not implemented by default.** User specified "optionally provide temporary disk-backed swap if testing reveals actual memory pressure." Leave as contingency; add a TODO comment in `partition_disk()` noting the hook location if QEMU tests (T-3/T-5) show OOM.

---

## Changes to `installer_spec.md`

Update to match new behavior (version bump to 1.5 in header):

| Section | Change |
|---------|--------|
| 0 (audience note) | Update "validate every package name **and every fatal service directory** against the mirror **before** touching any disk" — now: lightweight availability + service check; full validation after mount. |
| 4 (preflight) | No change (xbps self-update & canary remain). |
| 10 (sequence table) | Step 7: "Probe packages and services" → "Lightweight package/service probe". Step 11: "Prepare target for bootstrap" → add "full dependency + disk-space validation against /mnt". |
| 10.1 | Rewrite: replace dry-run code block with `xbps-query` batched check; explain `-M` memory-sync still used for probe queries; full dry-run moved to step 11. |
| 10.2 | Update `swapoff -a` to targeted logic; add rationale (never touch other disks). |
| 10.5 (bootstrap_prepare) | Add the dry-run command block with `--cachedir` and explanation. |
| 10.6 (bootstrap_install) | Add `TMPDIR` and `--cachedir` to command block. |
| 15.1 (test plan) | T-7: still exits 3 at step 7, disk unchanged. Add T-x: "Step 11 validation fails (e.g., disk too small for packages) → exit 1 with actionable message". |

---

## Validation / Testing

1. **ShellCheck** — `shellcheck install.sh` + embedded wrapper extraction (CI workflow).
2. **QEMU test T-3** (interactive install): Verify probe succeeds quickly, step 11 validation passes, step 12 installs.
3. **QEMU test T-7** (`EXTRA_PACKAGES="doesnotexist"`): Probe fails at step 7 with clear message, disk untouched.
4. **QEMU test T-24** (re-run): Targeted swapoff doesn't kill host swap if other disk present (hard to test in QEMU single-disk; verify no regression).
5. **Disk-space edge case**: Create a small test disk (just over 20 GiB) with a large package set — step 11 dry-run should fail cleanly with exit 1, not OOM on tmpfs.
6. **Bootstrap I/O verification**: After step 12, confirm `/mnt/var/cache/xbps` contains downloaded `.xbps` files and `/mnt/var/tmp` is clean.

---

## Rollout / Migration

- Single commit updating both `install.sh` and `installer_spec.md` (following 27a51a8 precedent).
- Version bump in `INSTALLER_VERSION` variable (currently 1.2.1 → 1.3.0).
- No config changes; `--yes` mode behavior unchanged.

---

## Open Questions (none — all resolved by user directives)

| Decision | Resolution |
|----------|------------|
| Probe batched vs per-package | Batched single `xbps-query` call (efficiency; stderr names missing packages). |
| Step 11 dry-run uses `-M`? | No — let it persist repodata to `/mnt/var/db/xbps` (mirrors real install). |
| Step 11 failure exit code | Exit 1 (disk already modified; ERR trap would fire anyway; explicit message). |
| Disk-backed swap default | Not implemented; contingency only. |
| TMPDIR export scope | Only for step 12 (bootstrap_install); step 11 dry-run uses cachedir only. |

---

## Implementation Order

1. `probe_packages()` rewrite
2. `bootstrap_prepare()` add dry-run
3. `bootstrap_install()` add `TMPDIR` + `--cachedir`
4. `partition_disk()` targeted swapoff
5. `installer_spec.md` full sync
6. Version bump
7. Run ShellCheck + manual review