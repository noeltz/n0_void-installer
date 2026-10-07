# Installer improvement progress

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
| 7. Resume and repair modes | 1.3.10 | Verified locally; awaiting commit/push | State rejection, checkpoint dispatch, and no-format/no-partition regressions pass. |

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
- Current next action: finish final review, commit/push release 1.3.10, and
  record the remote commit.
