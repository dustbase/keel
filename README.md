# Keel

**Prepare, secure, and eventually maintain Linux VPSs.**

Keel is an interactive, modular Bash CLI targeting Ubuntu 24.04/26.04 LTS.
It sets up an administrator, preserves SSH keys, optionally configures Tailscale,
sets hostname and unattended security updates, and applies UFW application-port
profiles with guarded SSH changes.

> Experimental v0.1. Disposable-VM acceptance testing and independent security
> validation remain required. Do not use this draft on production servers.
> Timed recovery cannot replace provider rescue-console access.

## Getting started

Review a pinned revision before running code as root:

```bash
git clone https://github.com/dustbase/keel.git
cd keel
sudo bash bin/keel init
```

Preparation installs `/usr/local/bin/keel` -> `/opt/keel/bin/keel` and its modules.
It detects the current account/hostname and lets you choose an existing or new
administrator, hostname, optional Tailscale/tag, authentication mode, and firewall
profile. Valid original public-key entries are copied verbatim and merged with
existing destination keys. **Those identities receive access to the administrator
account, which has sudo.** Original accounts and keys are retained.

If no usable public key is found, paste one or follow local ed25519 key-generation
instructions for macOS, Linux, or Windows. Never paste a private key. A newly
created account's local password is for sudo; OpenSSH password login is disabled
only in the guarded security phase.

Choose one of three access modes:

| Mode | Authentication | Preparation before verification |
| --- | --- | --- |
| Public OpenSSH | SSH public key | Keep the actual current listener port |
| OpenSSH over Tailscale | SSH public key | Connect the host and your computer to the tailnet |
| Tailscale SSH | Tailnet identity and SSH policy | Configure tailnet policies, then run `sudo keel tailscale-ssh` |

Enable Tailscale SSH **before** verification. Enabling it can interrupt existing
Tailscale connections; keep public recovery access or a rescue console available.
Keel does not edit your tailnet policy. Tailscale SSH is a separate SSH server:
OpenSSH settings do not govern its authorization.
For Tailscale SSH, open an interactive login without a remote command, for example
`tailscale ssh USER@HOST -o ControlMaster=no -o ControlPath=none`, then type the
Keel commands at its prompt. Current Ubuntu login layouts require trusted logind
and daemon PTY/session records; unsupported command helpers fail closed.

From a genuinely new connection as the administrator, run **without sudo**:

```bash
ssh -o ControlMaster=no -o ControlPath=none -p YOUR_SSH_PORT USER@HOST
keel verify
keel secure
```

Keel checks privileged server-side evidence, the selected authentication mode,
actual sudo execution, and connection freshness. It refuses when the evidence
cannot be established; environment variables and a new terminal are insufficient.
Run directly from SSH, rather than from tmux/screen or a nested login shell with
an unrelated process ancestry. [Evidence requirements and limits](docs/security.md).

After hardening, establish **another new connection**, then run:

```bash
keel confirm
```

You have five minutes from recovery arming. Confirmation must use a connection
established after the changes completed. A different pre-existing session or
multiplexed channel cannot cancel recovery. Failed/expired confirmation keeps
recovery armed. Keep the initial sessions open until successful confirmation.

```bash
sudo keel doctor    # Read-only observations and limitations
sudo keel status    # Pending transaction, phase, backup, timer
sudo keel rollback  # Explicitly restore a pending transaction
```

## Firewall profiles and boundaries

- **Private (default):** no public application ports.
- **Public web:** public TCP 80/443.
- **Cloudflare Tunnel:** no public application ports; cloudflared is not installed.
- **Custom:** explicit comma-separated port/protocol pairs, such as
  `25565/tcp,51820/udp`.

Management access is separate: preserve the verified public OpenSSH port, or
close public SSH and use the verified Tailscale path. UFW IPv6 must be enabled.
Unrecognized existing UFW rules and active competing firewall managers block
hardening. Known Keel rules can be reused when their confirmed baseline matches. Profile
changes add replacement access first, then remove obsolete Keel-managed rules;
unknown rules are never silently adopted.

**Tailnet grants and Tailscale's networking rules are separate policy layers.**
Do not infer tailnet service isolation from UFW alone. **Docker-published ports can
bypass UFW.** Keel does not manage Docker networking, provider firewalls, or tunnel
services. Local diagnostics cannot prove external IPv4/IPv6 reachability.

## Recovery and repeat execution

Root-private configuration/state/backups live under `/etc/keel`, `/var/lib/keel`,
and `/var/backups/keel`. Configuration is validated data, not executable shell.
Mutations, confirmation and recovery share a lock. Recovery snapshots include
SSH drop-in presence/content, all UFW files, `/etc/default/ufw`, and original UFW
status, plus a pinned runtime. A checked systemd timer is armed before restrictive
writes; an installed boot service handles unfinished transactions after reboot.
Recovery failures retain pending state and backups instead of reporting success.

Preparation is additive and can be rerun after partial failure; package installs,
accounts, hostname and Tailscale enrollment are not globally rolled back. Keel
never removes the original administrator or automatically reboots. Pending
security transactions block preparation, reinstallation and mode changes.
See [recovery procedures](docs/recovery.md).

## Supported configurations

The initial target is Ubuntu 24.04/26.04 with systemd, standard OpenSSH service and
include layout, and UFW. SSH `Match` blocks, custom/nested includes, alternate sshd
configuration files/options, and complex existing firewalls require manual review
and are rejected rather than silently rewritten. Both target releases still need
the complete disposable-VM acceptance matrix.

## Development

```bash
bash tests/run.sh
shellcheck -x bin/keel lib/*.sh tests/*.sh
```

The regression suite uses temporary files and mocked host commands, never host
firewall or account changes. See [v0.1 specification](docs/SPEC.md),
[architecture](docs/architecture.md), and [VM acceptance checklist](tests/integration/README.md).
