# Access guidance validation — 2026-11-19

The full regression suite and ShellCheck passed in the authorized UTM Ubuntu
26.10 ARM64 guest. Fixtures cover connections before/equal to the preparation
boundary, acceptance of a fresh connection, changed intent, prior boot, malformed
and missing preparation evidence. The original `keel_after_boundary` gate remains
authoritative; only refusal diagnostics and reconnect instructions changed.
Failed verification writes no new verification and leaves configuration intact.

Reconnect fixtures check which terminal runs SSH versus verify/confirm, disabled
multiplexing, administrator/target output, nondefault ports and IPv6/default-port
output. Presentation fixtures distinguish public OpenSSH, OpenSSH over Tailscale
and Tailscale SSH by authentication method. Preparation, doctor and the pre-apply
security plan use the same label helper. The mutation lock and its messages are
unchanged, as requested.

No real VPS was accessed and no live security transaction was applied for these
changes. Fixtures do not establish external NAT/proxy reachability, all client SSH
configurations, or supported-LTS acceptance. The reconnect command is guidance,
not authentication evidence; public NAT/proxy mappings may need the original
client target substituted by the operator.
