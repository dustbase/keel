# UTM live failure tests — 2026-11-16

The user authorized these tests inside the same disposable Ubuntu Server VM.
Ubuntu 26.10 ARM64, UTM 5.0.8/QEMU 10, one virtual CPU, 4 GB RAM. This extends the
[earlier exploratory results](UTM-2026-11-16.md); Ubuntu 24.04/26.04 acceptance is
explicitly deferred. No real VPS or other VM was accessed.

Luna created and verified the live `Keel Failure Baseline 20261116` snapshot.
Fresh Install and the two earlier Keel snapshots remained preserved. A separate
root-private copy of the installed runtime, SSH/UFW/default-policy files, Keel
configuration/state and Frank's exact authorized_keys bytes was also saved.

## Method and limits

The VM-only harness checks the known guest OS, architecture, network MAC,
checkpoint marker and one-CPU configuration before every root operation. All
security applications and confirmations use the ordinary CLI from actual fresh
key-authenticated SSH sessions with real administrator sudo. Multiplexing is off.

Temporary root-controlled pause points were added only to the guest test runtime:
after actual firewall application but before leaving phase `applying`, immediately
before confirmation's commit decision, and before rollback's restoration. No
session, freshness, preflight, backup, locking, deadline or recovery gate was
bypassed. The points force specific interleavings; they do not establish that all
possible uninstrumented timings have been explored. The shipping source contains
no pause points. Pristine security/transaction modules were restored between cases.

## Interrupted application

Each case applied actual IPv4/IPv6 web grants, observed phase `applying`, and
verified the independent recovery timer was active before signalling the exact
root secure PID. PID identity was checked against its birth time and command.

- SIGTERM: immediate trap recovery passed; client exit 143.
- SIGHUP: immediate trap recovery passed; the current trap also exits 143.
- SIGKILL: no trap could run. The original native five-minute systemd timer ran
  its pinned recovery runtime and completed successfully. The SSH transport
  returned 255 because the killed remote process supplied no exit status; the
  harness's initial assumption of transport exit 137 was corrected. Signal
  delivery, retained `applying` state and timer-service evidence establish this
  case independently of the transport exit value.

Each recovered case cleared pending state, reached `rolled_back`, matched exact
SSH drop-in, complete UFW tree and `/etc/default/ufw` bytes, matched UFW modes and
ownership, and retained Frank's original authorized_keys bytes. The SIGKILL timer
service reported successful completion; no manual rollback substituted for it.

## Confirmation and rollback races

Both tests used real concurrent CLI/service processes and observed the waiting
worker in `flock` before releasing the process holding the shared lock.

- Confirmation first: a fresh authenticated confirmation held the lock at its
  validated commit point. A rollback worker queued behind it. After release,
  confirmation committed; the waiting worker exited successfully without
  restoring the backup. Confirmed/applied policy digests matched, with no pending
  transaction and original keys unchanged.
- Rollback first: rollback held the shared lock. A fresh authenticated
  confirmation queued behind it. Recovery restored the exact backup and cleared
  pending state; the waiting confirmation then rejected with `No pending
  transaction` and exit 1. No commit occurred.
- A stale recovery invocation carrying the previous committed transaction ID
  left a different newer pending transaction, its phase, and applied digest intact.

## Denied Tailscale access

This tests **node-local incoming denial and disabled-server mode**, not shared
coordination policy denial or identity expiry. No tailnet-wide rule was changed.

A fresh interactive Tailscale SSH login first passed Keel verification. The VM's
`ShieldsUp` preference was then enabled with a separate one-minute automatic reset
armed beforehand. A fresh connection to this node was denied/timed out, while the
public-key recovery path remained available. The preference was restored, and a
new interactive identity login verified again. SSH/UFW/default-policy bytes and
original keys were unchanged; no security transaction was created.

After disabling the separate Tailscale SSH server, genuine OpenSSH public-key
login to the node's tailnet IP still worked, but Keel refused to treat that login
as the selected identity mode. It exited 1 before restrictive changes. Both
`RunSSH` and `ShieldsUp` were returned to false.

The local denial behavior follows the documented
[Tailscale incoming-connection control](https://tailscale.com/docs/features/tailscale-ssh).
Shared SSH/network policy denial and identity expiry remain separate acceptance
cases; the local control must not be represented as their proof.

## New administrator and no-key preparation

Dedicated accounts `keel_nokeysrc` and `keel_newadmin` were used. The first had no
keys. The real root-preparation path selected that source and created the new
administrator through Keel's actual `adduser`/password prompts. A strong generated
test-only password was supplied privately; Frank's password was never changed.

Finishing key entry without a usable key correctly refused preparation, left the
previous stored intent and Frank's keys unchanged, and retained explicit additive
incomplete-preparation state. It also exposed a cleanup fault: both root-owned
key staging files remained in an isolated test staging directory.

`keel_keys_setup` now scopes its staging files and EXIT cleanup to a subshell,
preserving the caller's EXIT/recovery trap. Both allocations and protection are
checked explicitly. A regression first failed against the old helper, then passed
with the fix, covering cancelled key entry and second-allocation failure. The
full smoke suite, all **22 fixture groups**, and ShellCheck 0.11 passed in this VM.

The actual cancelled-entry flow was repeated with the fixed installed helper;
no staging files remained. A subsequent real preparation rejected a malformed
public key, accepted the valid pasted public key, installed its exact entry with
owner `keel_newadmin`, directory mode 700 and file mode 600, and retained Frank's
original file byte-for-byte. The expected entry is the pasted public key, rather
than the entire original account file and its unrelated formatting.

The new administrator then completed actual public-key SSH plus password sudo
verification, guarded hardening, and independent fresh-connection confirmation.
No passwordless sudo rule was introduced. Frank remained able to log in.

## Finalization

Frank's public-key/private intent was prepared again, then ordinary verification,
hardening and fresh-connection confirmation succeeded. Only the dedicated test
accounts were locked/expired; the test administrator was removed from sudo and
its added test key archived. A new login attempt as that account was refused.
Frank's original credentials/keys remained intact.

Final checks found confirmed matching intent/policy digests, no pending
transaction or active Keel rollback timer, expected effective OpenSSH key-only
settings, active private UFW policy, RunSSH=false, ShieldsUp=false, and empty key
staging. The installed runtime matched the fixture-validated source exactly,
except for the documented guest-only Ubuntu 26.10 release guard. No fault hooks
remained. The VM stayed running with one CPU.

The snapshot predates the key-staging cleanup fix; loading it requires redeploying
the current source. After a fresh collision check and backup, all 22 validated source files were
integrated into the main checkout at `/Users/frank/Documents/GitHub/keel`.
All five pre-existing untracked archives and the Git index were preserved.
Source bytes/modes matched the validated working copy. No commit or push was made. Further LTS acceptance remains deferred, and PR #1
stays draft.
