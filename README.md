# Keel

**Prepare, secure, and eventually maintain Linux VPSs.**

Keel is an interactive, modular Bash CLI targeting Ubuntu 24.04/26.04 LTS.
It sets up an administrator, preserves SSH keys, optionally configures Tailscale,
sets hostname and unattended security updates, and applies UFW application-port
profiles with guarded SSH changes.

> Experimental v0.1. Disposable-VM acceptance testing and independent security
> validation remain required. Do not use this draft on production servers.
> Timed recovery cannot replace provider rescue-console access.

## Install or update (experimental)

Use the same command to install Keel or update an existing installation on a
disposable Ubuntu 24.04/26.04 VM with working SSH and console recovery:

```bash
curl -fsSL https://raw.githubusercontent.com/dustbase/keel/main/install.sh | sudo bash
```

This installs or updates the runtime without rerunning preparation or changing
your accounts and settings. If the pinned version is already installed, it is a
no-op apart from repairing the command symlink. After an update, establish a fresh
SSH login and run `keel verify` before hardening.

**First-time preparation:** after a new installation, run:

```bash
sudo keel init
```

**Optional combined install/update and preparation:** use this only when you want
to run or rerun the interactive setup prompts:

```bash
curl -fsSL https://raw.githubusercontent.com/dustbase/keel/main/install.sh | sudo bash -s -- --init
```

This remains an experimental installer preview, not completed LTS acceptance. The
bootstrap downloads a pinned commit archive and checks its embedded SHA-256 before
extraction or loading code. It never automatically verifies, hardens, or confirms
access. For review before execution, download `install.sh`, inspect it, then run
`sudo bash install.sh`. The checksum verifies the payload; the bootstrap itself
remains code you must trust/review. Install `curl` first if needed.

Pending recovery blocks installation and updates. An exact matching runtime is a
no-op apart from repairing its command symlink. Untrusted layouts or unrelated
`keel` commands are refused. Automatic updates require Python 3 and Linux atomic
directory exchange; Keel refuses an unsupported exchange instead of replacing
files sequentially. The preview's runtime
pin is `5c4d61a737102dd09971eae09a39b15ab6f2a7e2`; updating it requires reviewing
the new runtime and updating its archive checksum together.

Updates preserve settings, accounts, keys, and SSH/firewall configuration, and
invalidate old verification so you must establish a fresh login before hardening.
The prior runtime is retained under the printed `/opt/.keel-upgrade.*/runtime`
recovery path. Recovery directories are root-private and never automatically
deleted. The runtime directory swap is atomic; after interruption, a complete old
or new runtime remains installed. If publication or a later check fails, stop and
inspect the installed/recovery trees from independent recovery access. A staged
status can mean interruption before or after the swap; do not assume which tree
is old without inspecting it. Keep console recovery available during updates.
Adding `--init` explicitly reruns additive preparation after the update, with the
existing hostname and administrator offered as defaults.

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
Selecting this mode in `init` does not enable the server. Follow the printed
incomplete-setup checklist: configure both network and SSH access for the actual
server tag and administrator, test independent recovery access, then run
`sudo keel tailscale-ssh`. Reconnect through MagicDNS or the Tailscale address
before verification. A public-IP login uses OpenSSH and cannot verify this mode.
Keel does not edit your tailnet policy. Tailscale SSH is a separate SSH server:
OpenSSH settings do not govern its authorization.

Preparation prints a Tailscale policy template for the selected mode. To print it
again from a prepared checkout/installation:

```bash
sudo keel tailscale-policy --tag tag:my-server --port 2222 > tailscale-policy.json
```

For OpenSSH over Tailscale, pass the actual OpenSSH listener port; otherwise the
output leaves an explicit port placeholder. For Tailscale SSH, omit `--port`
(its separate server uses port 22). The template grants network access to a
placeholder group; Tailscale SSH additionally includes a check-mode SSH rule for
the selected local administrator only. Public OpenSSH emits no tailnet policy.
New preparation saves the selected tag for later template generation; `--tag`
overrides it. Legacy installations without saved tag intent retain a placeholder.

Replace all identity/tag/port placeholders and merge entries into existing policy
sections in the Tailscale editor. Choose tag owners separately from SSH users and
apply the destination tag only to intended servers; tagging changes device
identity. Review existing broad rules and group names: adding this snippet cannot
restrict access already allowed elsewhere. This is an example, not a replacement
policy or evidence of access. Keel never uploads it or changes tailnet permissions.
See Tailscale's [grants](https://tailscale.com/docs/reference/syntax/grants) and
[SSH policy reference](https://tailscale.com/docs/reference/syntax/policy-file#tailscale-ssh).

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

Human output uses consistent sections, aligned details and explicit status labels.
Doctor ends with counts of passed checks, warnings and unknowns; those counts do
not establish overall security. Tailscale health warnings are shown beside a short
node summary instead of the entire peer list. Colors appear only in capable
terminals; redirected output is plain text. To disable terminal colors explicitly:

```bash
sudo env NO_COLOR=1 keel doctor
```

Policy templates remain copyable JSON. Internal authentication evidence, stored
state and firewall fingerprints are not formatted or colored.

Doctor also reports Docker's running-container bindings, network modes, reported
firewall backend and Swarm state. On a manager it lists published service ports,
including ingress publication. Non-loopback publications outside the selected
application profile are flagged as potential conflicts; even matching ports are
not proof of effective filtering. Host/shared namespaces, worker-only inventory,
missing daemon fields and failed inspections remain explicitly unknown.

Docker inspection is read-only and uses only the local `/var/run/docker.sock`;
remote Docker contexts and rootless engines are outside this report. It avoids
container environment/secrets and never edits Docker or firewall rules. It also
runs when no Keel configuration exists, without a profile comparison. External
IPv4/IPv6 probes and review of network drivers/direct routing are still required.
See Docker's [firewall](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
and [Swarm publication](https://docs.docker.com/engine/swarm/ingress/) documentation.

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
shellcheck -x install.sh bin/keel lib/*.sh tests/*.sh
```

The regression suite uses temporary files and mocked host commands, never host
firewall or account changes. See [v0.1 specification](docs/SPEC.md),
[architecture](docs/architecture.md), and [VM acceptance checklist](tests/integration/README.md).

For Tailscale modes, preparation and `sudo keel doctor` report MagicDNS settings
and advertised node names. Reconnect instructions prefer the matching short name
with a Tailscale IP fallback. Client DNS resolution remains a separate check; use
the displayed full DNS name if your client lacks the tailnet search domain.
