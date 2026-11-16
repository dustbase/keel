# Disposable-VM release acceptance

Status: **Ubuntu 24.04/26.04 release acceptance remains pending**. Exploratory
checks ran in an explicitly authorized UTM Ubuntu 26.10 VM; see the
[2026-11-16 results and limits](UTM-2026-11-16.md) and the subsequent
[live failure tests and key-staging fix](UTM-failures-2026-11-16.md). No real VPS
was accessed.
Unit/fixture tests and 26.10 results do not satisfy the LTS acceptance matrix.

Use disposable Ubuntu 24.04 and 26.04 images with independent serial/console
recovery. Record image/package versions, Keel revision, commands, exit codes,
external probes, systemd/journal evidence and recovery results. Take snapshots
between cases. Keep at least two client terminals and disable SSH multiplexing
unless testing its rejection. Never use an existing VPS or shared CI host.

| Area | Required positive and negative cases |
| --- | --- |
| Installation | checkout -> installed symlink; help and every documented subcommand; repeat install; refuse pending upgrade |
| Accounts | root and sudo initial login; reuse admin; create admin; sudo password; no existing keys; preserve existing destination keys; no trailing newline; restricted keys; malformed/private keys |
| OpenSSH | public keys; password rejected by verify; Tailscale transport; IPv4/IPv6; nondefault listener; ssh.socket activation; missing journal evidence; package split-process variants |
| SSH layout | ordinary early include; overriding earlier drop-in; Match User/Address/Group; custom/nested include; alternate -f/-o options; preflight refuses unsupported contexts |
| Freshness | pre-prepare login; two pre-hardening sessions; new multiplexed channel; post-apply new login; stale intent; verification expiry; reboot identity |
| Tailscale SSH | enable before verify; direct and monitor process versions; journal format; denied network/SSH policy; disabled SSH; identity expiry; tailnet root access documented separately |
| Firewall | all four profiles; TCP/UDP custom bounds; default-policy backup; originally enabled/disabled; original custom rules refused; IPv6 off refused; competing manager refused; web-to-private closes old ports; new management rule precedes old-rule deletion |
| Boundaries | probe public and tailnet service access; Docker published-port bypass warning; provider firewall untouched; cloudflared not installed |
| Recovery | systemd-run failure; timer inactive; partial SSH write/reload/UFW failure; shell exit; TERM/HUP; SIGKILL; reboot in armed/applying/awaiting state; restoration failure/retry |
| Races | confirm vs timer/rollback; old timer vs new transaction; two secure/init processes; crash immediately after committed decision |
| Repeatability | second secure is no-op only after real checks; changed intent/config invalidates old proof; rerun additive prepare after each interrupted step |
| Updates | effective unattended policy on both releases; conflicting automatic-reboot setting rejected; no reboot triggered |

Do not mark the PR ready, release, or describe all modes as validated until actual
results are recorded. If a package layout cannot provide trusted evidence, retain
its fail-closed behavior and document the unsupported version.
