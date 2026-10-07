# Installer improvement progress

## Lightweight desktop implementation

Each increment is verified, committed, and pushed before the next begins.
Resume uses the exact installer version that wrote the checkpoint. VM
acceptance remains separate from automated checks; failed checks and the next
recovery action are recorded here.

| Increment | Release | Status | Verification / next action |
|---|---:|---|---|
| Wayfire, wf-shell, kitty and synchronized keyboard | 1.3.11 | Complete; pushed | Commit `83dc0f6`; all regressions, ShellCheck and syntax pass. |
| Greetd and tuigreet on tty7 | 1.3.12 | Complete; pushed | Commit `9bb6160`; Greetd/desktop and existing regressions, bootstrap, ShellCheck and syntax pass. |
| Graphical first-login chezmoi | 1.3.13 | Complete; pushed | Commit `20e727d`; all eleven regressions, installer/three helper ShellCheck, syntax/help/diff checks pass. |
| Stop duplicate elogind startup | 1.3.14 | Complete; pushed | Commit `0b0cefe`; all eleven portable regressions, syntax, diff checks and ShellCheck pass (CI run `37613486871`). VM acceptance is pending because this workspace has no QEMU runner. |
| Desktop fonts, icons and matching battery dependencies | 1.3.15 | Implemented; verified locally | All eleven portable regressions, syntax/help/diff checks and installer/three-helper ShellCheck 0.9.0 and 0.11.0 pass. Real host Fontconfig accepts the production font check. QEMU acceptance pending. |

Decisions: use Wayfire, wf-shell, kitty, greetd and tuigreet with required runtime assets;
greetd uses tty7, tty1 remains a recovery console; derive Wayfire XKB settings
from KEYMAP without a separate setting; open first-login setup in kitty.

- Release 1.3.15 corrects missing runtime assets: explicitly install DejaVu
  fonts and Adwaita icons, and include the battery widget only for the laptop
  profile that installs UPower. Final/repair checks query fonts as the desktop
  user and check icon and configured battery dependencies. Existing configs
  stay preserved; the README documents recovery without reinstalling.
- User QEMU diagnosis: Wayfire and wf-background run, Kitty and wf-panel do
  not; `fc-list` is empty and no UPower package version was reported. Missing
  fonts are confirmed; the panel's exact failure needs runtime error output
  if restoring assets and correcting the battery widget does not resolve it.

- Increment 1 inspection found that fresh config loading cleared passwords;
  secret clearing was moved to resume; fresh configured secrets are covered by a regression.
- Increment 1 also fixed resume dispatch suppressing Bash error handling; an injected action failure now stops without advancing its checkpoint.
- Verification: all nine regression scripts, installer/embedded-helper ShellCheck, syntax, help and diff checks pass. Initial state fixture lacked the new total-step constant; corrected and rerun.
- Remote packages confirmed: wayfire 0.11.0_1, wf-shell 0.11.0_2, kitty 0.48.2_1, greetd 0.10.3_2, tuigreet 0.11.1_1.
- Increment 1 pushed as `83dc0f6`. Increment 2 retains Void's `_greeter` account, packaged PAM and runit service; enables greetd and removes only the tty7 agetty link.
- Actual Void greetd package configuration and tuigreet 0.11.1 source verified: first discovered native session is selected automatically; remembered sessions keep using the wrapper.
- Increment 2 test note: the bootstrap fixture's localhost socket was blocked in the sandbox; rerun with network permission. No product-code failure remains.
- Increment 2 pushed as `9bb6160`. Increment 3 adds a Wayfire autostart launcher for kitty, checks the shared setup lock/state before launch, and holds a separate GUI lock while output remains visible.
- Increment 3 verification: PTY GUI helper, shared console/GUI locking, completion/failure/interruption gating, no duplicate terminals, skipped empty/install modes, autostart preservation and final hook/config checks pass. An expanded validator fixture initially rewrote a literal command comparison as a target path; the fixture adaptation was corrected and rerun.
- Increment 3 pushed as `20e727d`; all three implementation increments are delivered on `origin/main`.
- Remote CI failed at ShellCheck: Ubuntu uses 0.9.0, which flags omitted optional arguments and the helper status-read shorthand. Explicit production paths and conditional reads fix the warnings without changing behavior. The first compatibility patch fixed installer lint; testing the extracted scripts then exposed the status-read warning, now fixed.
- Both ShellCheck 0.9.0 and 0.11.0 pass for the installer and all three embedded scripts. Affected boot/desktop/greetd/resume/chezmoi/graphical regressions pass.
- The next remote CI run passed all lint and exposed a fixture portability issue: its optional host-registry check used Ubuntu XKB, which lacks Void’s ABNT2 model. That additional host check now runs only on Void; deterministic target fixtures still run everywhere, and the actual target registry check remains mandatory during installation. Local desktop regression passes. All representative conversions were additionally verified against the actual `xkeyboard-config-2.48_1` archive from the configured Void mirror, including ABNT2.
- Final CI compatibility commits `8f1f95a`, `614b482` and `f092213` are pushed. [GitHub CI for `f092213`](https://github.com/noeltz/n0_void-installer/actions/runs/37609687833) passed installer lint, all generated-helper lint and the six portable regression scripts. All eleven local regression scripts passed.
- Current next action: fresh VM acceptance T-30–T-33 and recovery of the reported QEMU desktop. Implementation and automated verification are complete; graphical runtime verification remains pending.
- VM acceptance: T-30–T-33 pending; this workspace has no VM runner. Use a fresh install for desktop/greetd/first-login acceptance. Resume still requires the exact initiating version.

Implementation is split into seven independently reviewed releases. A later
increment starts only after the current increment's checks pass and its commit
is pushed. Failures and the next recovery action are recorded here so work can
continue from the last completed checkpoint.

| Increment | Release | Status | Verification / next action |
|---|---:|---|---|
| 1. Cleanup ownership and disk safety | 1.3.4 | Complete; pushed | Commit `3c26b75`; cleanup and account regression checks passed. |
| 2. Logs, final checks, checkpoint records | 1.3.5 | Complete; pushed | Commit `f6eca17`; local syntax, cleanup/state redaction regressions, account regression, help, and diff checks passed. ShellCheck was unavailable locally. |
| 3. EFI fallback boot | 1.3.6 | Complete; pushed | Commit `fefce60`; local Secure Boot and GRUB invocation regressions pass. OVMF boot remains a VM acceptance check. |
| 4. Cached repository probes | 1.3.7 | Complete; pushed | Commit `e20ab3a`; signed local XBPS fixture confirms package/service outcomes and no repeat index downloads. |
| 5. First-login chezmoi | 1.3.8 | Complete; pushed | Commit `74ee39c`; helper regression covers hook idempotence, tty/user gating, retries, locking, and no passwordless sudo. |
| 6. Target Wi-Fi profile | 1.3.9 | Complete; pushed | Commit `a0bfeef`; offline nmcli parses generated profiles; Wi-Fi and state regressions verify escaping, permissions, bounds, and secret exclusion. |
| 7. Resume and repair modes | 1.3.10 | Complete; pushed | Commit `c909a4a`; state rejection, checkpoint dispatch, and no-format/no-partition regressions pass. |

## Session notes

- Starting point: commit `9b52933` (`main` matched `origin/main`); worktree was
  clean.
- User tested installer 1.3.3 successfully, including root and user logins.
- User authorized all seven improvements, incremental implementation,
  progress tracking after failures, and commit/push after changes.
- Decisions: resume only with the initiating installer version; install EFI
  fallback on every fresh install; first-login chezmoi by default; configure a
  target Wi-Fi profile while retaining live-ISO networking as a prerequisite.
- Current increment 1 changes: recorded mount ownership, preflight checks for
  an occupied `/mnt`, disk mounts/read-only state/block-device holders, and
  fatal target swap deactivation. It also avoids overwriting or deleting a
  pre-existing temporary sudoers file.
- Increment 1 verification notes: the cleanup test initially modeled an
  absent mount as still present; corrected the fixture and reran successfully.
  The XBPS regression could not bind its localhost socket in the sandbox; it
  passed when rerun with the required network permission. No implementation
  failure remains.
- Commit `3c26b75` pushed to `origin/main` as release 1.3.4.
- Increment 2 current changes: mode-0600 live and target logs for non-dialog,
  non-chezmoi steps; config diagnostics omit values; a versioned target state
  records device UUIDs, non-secret settings, and last completed installer step;
  a final bootability/service/sudo validation step was added.
- Increment 2 test notes: the first test script draft had a Python string
  assembly error, then its harness initially nested the extracted `run_step`
  function instead of defining it. Both are corrected; cleanup and state
  regression tests now pass. No product-code failure remains.
- Increment 2 verification: `bash -n`, cleanup regression, state/log redaction
  regression, account regression, `--help`, and `git diff --check` pass.
  ShellCheck is unavailable locally.
- Commit `f6eca17` pushed to `origin/main` as release 1.3.5.
- Increment 3 changes: preflight detects enabled Secure Boot from efivarfs;
  GRUB attempts the named entry, then always writes the removable fallback;
  final validation requires `EFI/BOOT/BOOTX64.EFI`.
- Increment 3 verification: `bash -n`, boot/cleanup/state regression tests,
  and diff checks pass. No product-code failure remains. OVMF boot has not
  been run in this workspace.
- Commit `fefce60` pushed to `origin/main` as release 1.3.6.
- Increment 4 changes: package/service probes now use one temporary isolated
  XBPS repository cache; the preflight canary shares the cache; cleanup removes
  the cache on both success and failure. Target dependency planning remains on
  the mounted target.
- Increment 4 verification: signed XBPS repository regression passes. An
  initial assertion treated the service-package archive request as a
  metadata-cache miss; the test now tracks repodata requests separately and
  confirms later queries do not refetch indexes. Service-file inspection can
  still fetch the corresponding package archive. Syntax and related cleanup,
  state, and boot regression checks pass; ShellCheck is unavailable locally.
- Commit `e20ab3a` pushed to `origin/main` as release 1.3.7.
- Increment 5 changes: `CHEZMOI_MODE` defaults to first-login and offers an
  installation-time compatibility mode. The first-login helper checks the
  configured user and tty, locks concurrent runs, records completion/failure,
  and provides a manual retry without granting sudo.
- Increment 5 verification: `bash -n`, chezmoi helper regression (including
  generated hook idempotence), cleanup/state/boot regressions, and diff checks
  pass. ShellCheck is unavailable locally. No implementation failure remains.
- Commit `74ee39c` pushed to `origin/main` as release 1.3.8.
- Increment 6 changes: optional interactive/configured open or WPA-Personal
  profile, hidden-network setting, strict SSID/passphrase checks, escaped
  keyfile values, mode-0600 secret file, and secret-free checkpoint/log data.
  The final target check parses the generated profile with offline nmcli.
- Increment 6 verification: Wi-Fi profile, installer-state, cleanup, EFI,
  chezmoi, and syntax regressions pass; `git diff --check` passes. An initial
  test fixture used an unquoted SSID with a space and failed; quoting the
  fixture corrected it. No product-code failure remains. ShellCheck is
  unavailable locally.
- Increment 7 changes: added validated `--resume` and non-destructive `--repair`
  flows, atomic active/completed checkpoint metadata, idempotent retry behavior,
  package database audit/reconfiguration, secret re-prompts, and a 23-step
  install sequence. Repair offers check, chroot, password, GRUB, and initramfs.
- Increment 7 verification: syntax, bootstrap, account-password (in a user
  namespace), boot, chezmoi, cleanup, state, Wi-Fi, resume/repair, and diff
  checks pass. The first account regression invocation lacked root privileges;
  rerunning through the approved user namespace passed. Initial resume-test
  fixture omissions were corrected; no product-code failure remains.
- Commit `c909a4a` pushed to `origin/main` as release 1.3.10. QEMU acceptance
  tests T-28 and T-29 remain documented for real-VM validation.
