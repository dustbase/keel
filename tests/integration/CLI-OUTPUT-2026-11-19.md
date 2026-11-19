# CLI presentation validation — 2026-11-19

The full fixture suite and ShellCheck passed in the authorized UTM Ubuntu 26.10
ARM64 guest. Existing authentication, session freshness, rollback, interruption,
locale/fingerprint and automatic-update regressions remain enabled.

Presentation fixtures use actual pseudo-terminals to check automatic color,
NO_COLOR (including empty), TERM=dumb and narrow-terminal wrapping. Redirected
output is checked for absence of ANSI controls. Warnings/errors retain stderr
and failure exit semantics; message-provided terminal escapes are neutralized.

A mocked complete doctor report checks section headings, aligned update-policy
values, counts of passes/warnings/unknowns and preservation of Tailscale health
failures. Peer names are not dumped, and malformed status responses remain unknown.
The generated plain-text fixture report was also inspected for readability.

A guarded installed-runtime smoke test subsequently passed in the same UTM guest.
The local candidate runtime was staged through the updater; installed help,
doctor and status ran successfully. Redirected doctor output contained no ANSI,
and real pseudo-terminal status output honored automatic color and NO_COLOR.
The candidate's guest-local Ubuntu guard was extended only for exploratory 26.10
testing; shipping OS guards remain unchanged. Before/after SSH/UFW/configuration
and key hashes matched. The original runtime and expected verification/preparation
markers were restored afterward; no init, secure or recovery operation ran.

These tests do not establish supported-LTS acceptance or live Docker/Swarm
networking. No SSH/firewall/account policy was applied, no real VPS was accessed,
and the temporary installed UTM smoke test restored the original runtime. Public
policy JSON, authentication evidence, persistent state and security fingerprints
remain outside human-output formatting helpers.
