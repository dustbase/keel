# Keel

**Bootstrap, secure, and maintain Ubuntu servers.**

Keel is an interactive, modular Bash CLI for preparing a fresh Ubuntu VPS: administrator creation, SSH key discovery and preservation, hostname, optional Tailscale, unattended upgrades, and private-by-default UFW.

> **Experimental v0.1, not security audited.** Test on a disposable Ubuntu VM with recovery-console access before deploying to a real VPS. The rollback timer reduces certain lockout risks but does not guarantee recovery.

## Getting started

Review the code before running it as root:

```bash
git clone https://github.com/dustbase/keel.git
cd keel
sudo bash bin/keel init
```

`init` installs the command at `/usr/local/bin/keel` and copies its modules to `/opt/keel`.

Next, from a **new SSH session as the new administrator**:

```bash
keel verify
keel secure
```

After `secure`, you have **five minutes** to log in through **another new SSH session** and run:

```bash
keel confirm
```

This cancels the scheduled automatic rollback. If you cannot reconnect, the rollback timer attempts to restore the previous SSH and UFW configurations.

Run `sudo keel doctor` for a read-only report. If you chose Tailscale SSH and configured an appropriate tailnet SSH policy, run `sudo keel tailscale-ssh` to enable it.

## Supported platforms

Initially targets Ubuntu 24.04 and Ubuntu 26.04. Requires systemd, UFW and standard OpenSSH. Other Linux distributions, customized SSH key sources, and complex pre-existing firewalls are not supported yet.

## Features

- Detects the current sudo-invoking user automatically; prompts for new admin username and hostname.
- Lists SSH fingerprints from the original and new user accounts, preserves all existing authorized keys, and supports optional public-key pasting. If there are no keys, displays `ssh-keygen` instructions to run on **your own computer**.
- Never requests private SSH keys or automatically removes the old account.
- Optional Tailscale; can distinguish OpenSSH over Tailscale from Tailscale SSH.
- UFW profiles: **private** (default), public web (TCP 80/443), Cloudflare Tunnel (no inbound service ports), or explicit custom ports.
- Enables unattended security upgrades.
- Requires fresh-SSH-session verification before SSH/firewall hardening, and a second session to cancel an armed rollback timer.
- Root-owned configuration and state under `/etc/keel` and `/var/lib/keel`; backups under `/var/backups/keel`.

## Security boundaries

- Keel does not manage provider-side firewalls, Cloudflare Tunnel services, Docker networking, or Dokploy.
- **Docker-published ports can bypass ordinary UFW rules.** Do not assume a Docker dashboard is private just because Keel enables UFW.
- A local firewall report is not proof that a port is unreachable over IPv4 or IPv6. Test externally.
- The rollback relies on functioning systemd and the host staying online. Maintain rescue-console access.
- Existing UFW custom rules cause the secure phase to stop for manual review.
- We do not recommend deploying this draft version to production before VM integration testing.

See [Security design](docs/security.md).

## Development

```bash
bash -n bin/keel lib/*.sh
shellcheck -x bin/keel lib/*.sh
bash tests/smoke.sh
```

Test SSH/firewall changes only in disposable VMs, not on shared CI workers.
