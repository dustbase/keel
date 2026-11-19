# Docker doctor fixture validation — 2026-11-19

The full `bash tests/run.sh` suite and
`shellcheck -x install.sh bin/keel lib/*.sh tests/*.sh` passed in the authorized
UTM Ubuntu 26.10 ARM64 guest. Docker tests use private JSON fixtures and a strict
read-only CLI double; they do not contact or modify a Docker engine.

Coverage includes IPv4/IPv6 wildcard and loopback bindings; private/web/custom
profile comparisons (including normalized ports); host/shared network warnings;
reported iptables/nftables and absent backend metadata; Swarm manager publication
and worker inventory limitations; empty inventories; malformed/unavailable daemon,
container and service responses; and inspection without a Keel configuration.
Transport fixtures verify a fixed local socket and removal of remote-context
environment overrides. Container inspection requests only names, network mode
and port metadata, excluding container environment and secrets.

Data interpretation follows Docker's firewall/publication documentation and
Moby's `FirewallBackend.Driver` info response. An absent field remains unknown;
configuration-file guesses do not establish the effective backend.

No live Docker, Swarm, external IPv4/IPv6 or firewall-isolation validation was
performed for this change. Network drivers, direct routing, rootless/remote
engines and host-network listeners are explicitly outside its local publication
inventory. Mocks are not security proof. No development-host policy or real VPS
was changed, and the supported Ubuntu acceptance matrix remains pending.
