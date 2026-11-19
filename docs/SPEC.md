# Keel v0.1 behavioral specification

Status: experimental, pending disposable-VM acceptance testing.

## Product and platform

Keel is a provider-agnostic, interactive Bash CLI for Ubuntu 24.04/26.04 LTS
with systemd, standard OpenSSH, and UFW. It prepares accounts, keys, hostname,
optional Tailscale, unattended security updates, and private application-port
profiles. Unsupported configurations must produce actionable errors before
restrictive changes. Go, other distributions, drift remediation, provider APIs,
Docker/Dokploy/Wazuh installation, and cloudflared installation are out of scope.

## Preparation

- Detect the invoking login, hostname, OS and both accounts' authorized keys.
- Prompt for administrator, hostname, optional Tailscale/tag, SSH authentication
  mode, and private/web/tunnel/custom firewall profile. Keep an existing admin
  when selected. Validate all stored intent before use.
- Display fingerprints/comments. Preserve original keys and merge every valid
  original authorized-key entry by default, including restrictions/options.
  Explain that these identities receive access to the sudo-capable destination.
  Never merge same-key entries by dropping or weakening their options.
- Permit additional public keys; reject private keys and malformed entries. With
  no usable keys, offer pasted keys and local ed25519 generation instructions for
  macOS/Linux/Windows. Do not report key readiness from file size alone.
- Enable unattended security updates without automatic reboot. Do not delete
  the original account, reboot, or change provider firewalls.
- Preparation is additive and repeatable, not a globally reversible transaction.
  Refuse preparation and installation while a security transaction is pending.
- For Tailscale modes, preparation prints an advisory policy template; the
  read-only `tailscale-policy` command can regenerate it. Use explicit identity
  and destination-tag placeholders, network grants for the supplied OpenSSH port
  (an unresolved placeholder if unknown), or TCP 22 plus a check-mode SSH rule
  restricted to the prepared administrator for Tailscale SSH. Public OpenSSH
  emits no tailnet rules. Never upload or apply templates, infer authentication,
  or claim they restrict existing broad rules. Explain replacement of placeholders,
  merging into existing sections, tag ownership/device identity, editor validation
  and fresh-connection testing before access changes.

## Access and hardening

Workflow: Prepare -> Verify -> Secure -> Confirm -> Doctor.

- Public OpenSSH and OpenSSH over Tailscale require proven public-key login.
  Tailscale SSH requires its own enabled server and a proven authorized connection
  to that server; tailnet SSH policy remains operator-managed.
- Enable Tailscale SSH before verifying that mode, with an interruption warning.
  Preserve public recovery access until secure is applied.
- Tailscale SSH preparation must identify remaining setup steps rather than
  present a public-IP login as verification-ready. Preserve the selected tag as
  trusted advisory data for templates. Before enabling, display the template and
  require acknowledgment of network/SSH policy and independent recovery access;
  do not claim the external policy has been verified. Refuse unknown daemon state,
  make an already-enabled request a no-op, and durably invalidate old verification
  before a server switch can disconnect the process. Diagnose a disabled server
  and a proven OpenSSH login in the wrong mode separately from missing trusted
  session evidence; all remain blocked.
- Require actual administrator sudo execution. Correlate trusted server-side
  evidence with the invoking process ancestry; caller-provided SSH metadata is
  only a hint, never evidence. Unsupported evidence formats fail closed.
- Verification must follow preparation. Confirmation must follow completed
  restrictive changes on a fresh authenticated connection, not an old session,
  new multiplexed channel, or unrelated session. Bind evidence to boot, intent,
  connection, and change boundary.
- Validate SSH syntax, global and connection-specific effective settings.
  Reject unsupported conditional/include layouts rather than claim universal
  hardening. Preserve the actual verified OpenSSH listener port.
- Disable root/password/keyboard-interactive OpenSSH login, retain key login.
  Do not claim these settings control the separate Tailscale SSH server.
- Default-deny public inbound application traffic. Public web opens TCP 80/443;
  tunnel/private open no public service ports; custom supports validated TCP/UDP
  rules. SSH management is handled independently. Manage IPv4/IPv6 together.
- Detect unsupported existing firewall policy before changing it. Tailscale
  network/SSH grants and Docker-published ports are separate trust boundaries;
  UFW alone must never be described as proving their isolation. Track owned rules
  so web-to-private and management-path changes remove obsolete grants only
  after replacement access rules have been added.

## Transactions and recovery

- One mutator/recovery/confirmation at a time. Use root-private, validated state,
  atomic writes, a configuration digest, and a unique transaction ID.
- Snapshot all changed SSH/UFW configuration, including `/etc/default/ufw`, file
  absence and original UFW status. Pin a recovery runtime for the transaction.
- Publish pending state only after backup completion. Arm and inspect the timer
  before any restrictive write. Scheduling failure leaves no stuck pending state.
- Apply under a short bounded deadline. On failure or signal attempt immediate
  rollback; an independent systemd timer remains available. Installed boot
  recovery handles unfinished transactions after reboot.
- Serialize confirmation against rollback; persist the terminal decision before
  cleanup. Expired changes cannot be confirmed. Recovery is repeatable and retains
  pending evidence on failure. Never report failed restoration as complete.
- Expose read-only status and explicit rollback. Rescue-console access remains
  necessary: host failure and external network policy are outside this guarantee.

## Diagnostics and acceptance

Doctor reports observed facts, intended state and unknown checks separately. It
must not claim global security or external reachability from local checks. Reuse
the hardening checks so diagnostics do not disagree with workflow gates.

Automated regressions cover installed entrypoint resolution, strict config/key
parsing, newline merging, authentication evidence and freshness, Match behavior,
nondefault ports, complete firewall restoration, failed scheduling, stale intent,
concurrent operations, interrupted application and failed recovery.

Release acceptance additionally requires disposable Ubuntu 24.04 and 26.04 VMs
with console access: all three SSH modes, sudo, IPv4/IPv6, existing keys/no keys,
custom listener ports, socket activation, old/multiplexed connections, Tailscale
policy denial/expiry, UFW interactions, Docker warnings, timer/partial failure,
reboot while pending, confirm/rollback races, and repeat execution. Record actual
results and remaining gaps. Lint and mocked tests do not satisfy VM acceptance.

## Installer preview (v0.2 distribution work)

A public Bash bootstrap may install a reviewed, pinned full runtime archive after
checking an embedded SHA-256. Reject unsupported releases, malformed archives,
untrusted targets, unrelated command collisions, different installed versions,
and pending/legacy recovery before replacing runtime files. Recheck pending state
under the common mutation lock. Matching trusted installs are idempotent.

Installation does not apply SSH/firewall/account policy. An explicit --init option
may start additive preparation on a real terminal after installation and lock
release. Verify, secure, and confirm remain explicit fresh-login operations. The
installer is experimental until supported-release acceptance passes.
