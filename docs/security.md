# Security design and threat boundaries

Keel executes as root and changes authentication and firewall configuration. Always review source from a pinned revision before running it.

## Access verification

Preparation creates the administrator but makes no restrictive network changes. The verifier checks a fresh SSH session and sudo. The security phase schedules a systemd rollback, validates effective SSH settings and activates UFW. Confirmation must arrive from a different SSH session.

This protects against some lockouts but cannot replace provider rescue access. Systemd timer failure, provider firewall rules, network failure, and a compromised local machine can defeat recovery.

## SSH modes

OpenSSH over Tailscale still uses public-key authentication. Tailscale SSH uses Tailscale identity authorization and separately maintained tailnet SSH policy. Public OpenSSH is supported when Tailscale is absent. Keel does not delete the original account.

## Network limitations

Docker-published ports may bypass UFW; Cloudflare Tunnel requires a separate cloudflared deployment. Keel does not change provider firewalls, Docker networks, or configure external services. Test IPv4 and IPv6 independently.

## Reporting security issues

Never include private keys or credentials in public reports. Use private vulnerability reporting, when enabled for this repository, for sensitive discoveries.
