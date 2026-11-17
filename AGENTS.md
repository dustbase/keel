# Working on Keel

- Read `docs/SPEC.md` before changing behavior. Preserve the full v0.1 scope,
  including public OpenSSH, OpenSSH over Tailscale, and Tailscale SSH.
- Treat SSH, firewall, account/key handling, and recovery as safety-critical.
  Fail closed when connection evidence, effective settings, or recovery cannot
  be established. Never substitute environment variables for authentication proof.
- Keep preparation additive. Never delete original accounts/keys, request private
  keys, enable automatic reboots, or change provider firewalls.
- Serialize mutations and recovery. Arm and verify rollback before restrictive
  changes; keep backups and pending state when recovery fails. Do not rely on a
  shell trap alone, or on a transient timer surviving reboot.
- Bash is the v0.1 implementation. Keep the command router thin and separate
  session evidence, resource operations, and transaction coordination. Quote
  expansions, use arrays, avoid eval and executable configuration, and explicitly
  propagate failures in functions called from conditionals.
- Run `bash tests/run.sh` and `shellcheck -x install.sh bin/keel lib/*.sh tests/*.sh`.
  Add regression tests for safety fixes, including negative and interrupted paths.
  Tests must use temporary fixtures/mocks unless explicitly running the VM suite.
- Never run init/secure/recovery against the development host or a real VPS.
  Network integration tests require disposable VMs with out-of-band recovery.
- Do not merge, release, push, or change PR discussions without authorization.
  Report VM validation gaps honestly; mocks are not security proof. Do not claim
  LTS release acceptance until the supported-VM matrix has passed.
