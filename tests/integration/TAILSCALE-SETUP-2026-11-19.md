# Tailscale setup regression validation — 2026-11-19

The full `bash tests/run.sh` suite and
`shellcheck -x install.sh bin/keel lib/*.sh tests/*.sh` passed in the authorized
UTM Ubuntu 26.10 ARM64 guest. Tests used private fixtures and daemon/process
doubles; no real tailnet policy, SSH server, firewall or account was changed.

Policy fixtures cover both Tailscale modes, public OpenSSH, explicit custom ports,
administrator-only check-mode SSH rules, saved destination-tag reuse, unsafe or
malformed tag state, missing options, injection-like input and placeholder output.
Setup fixtures cover disabled/unknown daemon state, proven OpenSSH authentication
in the wrong selected mode, refusal of caller-provided connection metadata,
declined policy/recovery/enable prompts, an already-enabled no-op, failed durable
boundary writes, failed/interrupted/unconfirmed server switching, pending recovery
and refusal to switch a hardened host without proven public recovery access.
They verify that old verification is invalidated before the switch and that failed
enabling never prints the successful reconnect message.

The operator-provided Ubuntu 26.04 transcript motivated these changes: network
access covered `tag:dustbase-node`, but the SSH rule only covered `tag:dustbase`.
The transcript reports successful verification after correcting the tailnet policy.
This is operator-provided evidence for the previous runtime, not a live acceptance
test of this patch. No real VPS was accessed by the agent.

Live switching with the new prompts, all supported LTS combinations, external
IPv4/IPv6 isolation and the full acceptance matrix remain unverified. The installer
and runtime remain experimental; fixture success is not security acceptance.
