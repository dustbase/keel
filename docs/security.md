# Security model and evidence boundaries

Keel executes reviewed code as root. It assumes an uncompromised host, trusted
operator/sudo administrator, distribution packages, release checkout, and (when
selected) Tailscale service and tailnet administration. It does not defend against
an administrator who already has unrestricted root access and deliberately
modifies state or bypasses checks.

## Connection evidence

User-provided SSH environment variables never authorize verification or
confirmation. Keel follows the invoking process ancestry through sudo to a
privileged SSH server process. Local shells, unrelated tmux/screen servers, and
unsupported launchers fail closed. Actual sudo execution proves permission;
membership in a group alone is insufficient.

For OpenSSH, the accepted connection must belong to a root sshd ancestor with an
established kernel TCP socket. Its trusted journald records (`_PID`, `_UID=0`,
`_EXE`, current boot) must show `Accepted publickey` for the administrator and the
same peer address/port. Records must follow process birth to avoid PID reuse.
The privileged connection process start time supplies the freshness boundary.
The current adapter recognizes `/usr/sbin/sshd` and the split
`/usr/lib/openssh/sshd-session` executable; other layouts are refused.

For Tailscale SSH, Keel requires a root server-created login/su/incubator in its
ancestry, parented by the root systemd tailscaled daemon, directly or through its
per-connection SSH monitor. It reads connection metadata from that privileged
server-created process, checks the selected administrator against a matching
trusted daemon `ssh-conn-…: handling conn: SOURCE->USER@DESTINATION` journal event,
and checks that Tailscale SSH is enabled. The earliest matching connection event
supplies the age, so a new multiplexed session is not treated as new authentication.
If a source/destination tuple was reused during the same daemon lifetime, Keel
conservatively uses the oldest matching event; reconnect with a different tuple.
Daemon birth rejects stale PID records, and an already-open login's birth time
bounds delayed log timestamps. Unknown log/process formats fail closed. These
adapters are based on upstream OpenSSH/Tailscale formats and require live VM
validation across supported package versions; fixture tests alone do not prove
that each version emits the necessary evidence.

Journald must retain connection records for the current boot. If logs are missing,
forwarded without trusted fields, or unavailable, verification fails. Keep original
access and use `sudo keel status`; do not edit marker files to bypass verification.
A valid key fingerprint proves encoding, not that all authorized_keys options
permit interactive login. The actual login check is authoritative for access.

Both verification and confirmation are bound to boot identity and configuration
digest. Confirmation checks a monotonic post-apply boundary, recovery deadline,
SSH policy and applied SSH/UFW baseline. Password logins, stale verification,
pre-existing connections, and multiplexed channels cannot satisfy those checks.
Tailscale network/SSH policy is external and can change later; one successful
connection does not prove its future availability or global least privilege.

A runtime update advances the preparation freshness boundary while preserving
configuration. A connection that was already open at that boundary cannot verify:
keep it for recovery, open a new non-multiplexed interactive SSH connection, and
run `keel verify` there. This case does not require rerunning preparation. Missing,
malformed, prior-boot or changed-intent evidence remains refused separately.
Refusals for an old session print a copyable reconnect command and say which
terminal runs each step. The address/port come from the proven connection when
available; public NAT/proxy mappings may require the operator's original target.
This guidance is presentation only and never substitutes for server-side proof.

## SSH configuration

Keel writes one early drop-in and checks syntax plus global and administrator/root
connection-specific effective settings. It rejects Match blocks and nonstandard
includes rather than infer a universal guarantee from sampled contexts. Alternate
sshd options/configuration are unsupported. Actual listeners are checked separately
because socket activation can determine ports independently of sshd configuration.

Tailscale SSH uses a separate server. Disabling root/password login in OpenSSH
says nothing about tailnet root authorization. Keel never edits tailnet policies;
restrict them to the intended administrator and devices before verification.

## Recovery and network limits

See [recovery](recovery.md) for transaction behavior. A functioning host, storage,
systemd and SSH/firewall tools are required. Host failure, a broken recovery runtime,
external provider rules, Tailscale control-plane/policy changes, and network failure
can defeat recovery. Maintain out-of-band rescue access.

UFW default deny concerns public application traffic on a supported host. Existing
unknown rule sets require manual review. Tailscale may accept traffic through its
own chains before UFW; tailnet grants are a separate enforcement layer. Docker
published ports may bypass UFW. Neither a local check nor successful SSH login
proves application-port isolation over all networks or both IP families.

## Secrets and reports

Do not paste private keys or include credentials in issue reports. Key comments,
fingerprints, addresses and tailnet identities can identify people or machines;
redact diagnostics before sharing. Keel does not persist enrollment secrets or
request private keys. Private vulnerability reporting should be used when enabled.
## Tailscale SSH interactive-session requirements

On the observed Ubuntu 26.10/Tailscale 1.104.7 layout, an interactive login has
an actual root-owned `login` ancestor beneath the privileged SSH monitor. Ubuntu
clears that login process's initial connection environment. Keel instead checks
its kernel cgroup and root-owned logind record, requiring the exact leader PID,
administrator UID/name, remote service and PTY. It joins the root daemon's PTY
launch, session and original connection journal records. The launch must uniquely
match that terminal near the login process's birth; missing, recycled or ambiguous
records fail closed. The original connection timestamp supplies freshness even
when a new multiplexed channel creates a new login process.

Use a genuine interactive connection without a remote command:

```bash
tailscale ssh USER@HOST -o ControlMaster=no -o ControlPath=none
# At the remote prompt:
keel verify
keel secure
```

Use another genuinely new interactive connection for `keel confirm`.
Direct remote commands can run under an unprivileged `be-child ssh` helper;
that helper's environment is not accepted as authentication proof. Unsupported
session/logind/log formats still fail closed. See the
[VM test record](../tests/integration/UTM-2026-11-16.md) for results and limits.

## Tailscale SSH setup

Selecting Tailscale SSH during preparation does not enable its server. Keel prints
an incomplete-setup checklist and a policy template. The selected tag is saved
as root-private advisory data, not authentication evidence. Legacy installations
without that saved tag use a placeholder; supply `tailscale-policy --tag tag:NAME`
to generate an explicit template. Both network and SSH rules must cover the actual
server tag, with the intended local administrator in `users`. For a tagged server,
a default `autogroup:self` SSH rule alone is insufficient.

Before `sudo keel tailscale-ssh` switches servers, the operator must acknowledge
policy setup and tested independent recovery access. Keel cannot validate a future
login by inspecting local preferences. It invalidates verification and records a
new preparation boundary before enabling, so a disconnect or failed command cannot
leave old evidence usable. A failed enable may still have changed daemon state;
inspect it using recovery access. An already-enabled request changes nothing.
Policy denials happen before Keel runs: fix the tailnet policy, then establish a
fresh interactive login. Public-IP OpenSSH logins cannot verify Tailscale SSH mode.

## Stable firewall fingerprints

Keel fixes locale, output width and terminal presentation while computing the
SSH/UFW fingerprint. A client's forwarded locale must not change shell-glob
ordering or the serialized policy. Historical draft fingerprints that no longer
match remain refused; never silently adopt unfamiliar rules. Test upgrades from
a recorded recoverable baseline and repeat guarded verification/confirmation.
