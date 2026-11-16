# Architecture

Keel v0.1 remains Bash and Ubuntu-first. Preserve behavioral boundaries and tests
for a future Go implementation; do not build a generic plugin/resource framework.

- `bin/keel`: symlink resolution, command routing, sudo entry, locking boundaries.
- `common.sh`: validated/versioned data configuration, trusted paths, atomic state,
  locking, installation, platform and input checks.
- `prepare.sh`: interactive plan and additive package/account/hostname/Tailscale
  setup. Records incomplete preparation; does not claim global rollback.
- `keys.sh`: fingerprint validation, exact-entry merging, unprivileged access to
  user-controlled paths. Restrictions are preserved, never deduplicated away.
- `session.sh`: privileged process/kernel/journal evidence and freshness adapters.
- `ssh.sh`: supported-layout checks, effective policy, listener check and drop-in.
- `transaction.sh`: backups, pinned recovery, timer/boot recovery, terminal phases,
  baseline digest and read-only status.
- `security.sh`: verify/apply/confirm orchestration and firewall profiles.
- `doctor.sh`: local observations and explicit unknowns, reusing policy checks.

Configuration intent is distinct from observed evidence and transaction history.
Configuration schema and transaction schema each start at version 1. Legacy empty
shell-writer values can be read as literal data; configuration is never sourced.
Boot identity, monotonic boundaries and intent digests invalidate stale evidence.
Original keys remain; copying them to a sudo account is an explicit product choice
shown to the operator before preparation.

Only the SSH/UFW hardening window is transactional. Packages, account creation,
Tailscale enrollment and hostname changes are additive/recoverable operations.
Recovery requires a live host and trusted local services; provider networking and
tailnet policies remain external. Keel does not promise universal security.

Further distributions should add platform-specific package/service/layout adapters
when real implementations justify them. A future Go rewrite should retain config
migration, command behavior, evidence contracts and acceptance fixtures. Drift
monitoring can later compare intent, the confirmed baseline and current state;
automatic remediation must reuse guarded transactions. No Go migration or drift
remediation is included in this iteration.
