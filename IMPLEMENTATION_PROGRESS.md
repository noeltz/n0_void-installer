# Installer improvement progress

Implementation is split into seven independently reviewed releases. A later
increment starts only after the current increment's checks pass and its commit
is pushed. Failures and the next recovery action are recorded here so work can
continue from the last completed checkpoint.

| Increment | Release | Status | Verification / next action |
|---|---:|---|---|
| 1. Cleanup ownership and disk safety | 1.3.4 | Verified locally; awaiting commit/push | `bash -n`, cleanup regression (owned-mount identity/order and early exits), account regression, signed XBPS bootstrap regression, and `git diff --check` pass. ShellCheck is unavailable locally; CI will run it. |
| 2. Logs, final checks, checkpoint records | 1.3.5 | Verified locally; awaiting commit/push | Syntax, cleanup/state redaction regressions, account regression, help path, and diff checks pass. ShellCheck is unavailable locally; CI will run it. |
| 3. EFI fallback boot | 1.3.6 | Pending | Verify named-entry and fallback paths, including OVMF boot without an NVRAM entry. |
| 4. Cached repository probes | 1.3.7 | Pending | Extend signed local XBPS fixture to check one metadata sync and probe outcomes. |
| 5. First-login chezmoi | 1.3.8 | Pending | Test tty/user gating, retries, concurrency, and the no-passwordless-sudo default. |
| 6. Target Wi-Fi profile | 1.3.9 | Pending | Test keyfile parsing, permissions, input validation, and secret exclusion. |
| 7. Resume and repair modes | 1.3.10 | Pending | Inject checkpoint failures and prove resume/repair cannot format or partition. |

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
  ShellCheck is unavailable locally. Next: commit/push 1.3.5, then advance.
