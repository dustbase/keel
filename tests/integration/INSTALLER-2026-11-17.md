# Public installer preview validation — 2026-11-17

The user authorized these checks in the existing disposable UTM Ubuntu Server
VM: Ubuntu 26.10 ARM64, QEMU 10, one CPU, 4 GB RAM, with out-of-band console and
preserved snapshots. No other VM or real VPS was used. These exploratory results
do not establish Ubuntu 24.04/26.04 acceptance, which remains deferred.

## Fixture and static checks

The full smoke suite, 22 existing regression groups, initial five installer fixture
groups, and ShellCheck passed both in CI and on the authorized guest. After review,
the guest passed the full suite and ShellCheck again with a sixth installer group.
Bootstrap fixtures
cover ordinary/malformed/legacy pending markers, checksum acceptance/rejection,
archive traversal and links, exact runtime comparison, missing/extra modules,
and staging cleanup including namespace/symlink guards.

The review fix replaces the pinned helper's unchecked copies with an explicitly
checked bootstrap publisher. It stages and compares the full runtime beside the
destination, then publishes it with one rename before creating the command link.
Conditional-call fixtures inject directory, entrypoint and module copy failures,
plus a TERM interruption: none publishes a partial runtime or command, staging is
removed, and a retry succeeds. Command-link failure propagates a nonzero result
while retaining a complete matching runtime that a repeat installation can repair.
The live installation/refusal/repeat checks below were rerun successfully with
this fixed publisher, and the original guest runtime was again restored exactly.

The installer pins runtime commit `f94dac7c1dc34b458e1929122dab0a3e2fbc1ee7` and
archive SHA-256 `c0c9618678f8d45e991ed272188cda0755d3c60602f1c81a53fd370b10688534`.
The public archive and immutable bootstrap were also downloaded anonymously and
compared with their expected content. The embedded checksum verifies the payload;
the bootstrap itself still requires trust/review.

## Live installation and refusal checks

The unmodified public bootstrap rejected Ubuntu 26.10 before installation. For
the remaining exploratory checks, only a guest-local copy of the bootstrap's OS
check was extended to 26.10. The downloaded public runtime, archive checksum,
path/trust checks, mutation lock and recovery checks were unchanged.

- The different pre-existing guest runtime was refused without replacement.
  Its full tree still matched the before-test copy.
- `--init` without a controlling terminal was refused before installation.
- After moving the original runtime into a root-private backup, the bootstrap
  downloaded the real public HTTPS archive, verified its embedded checksum,
  extracted/installed all modules, and created the expected command symlink.
  The installed `keel help` command ran successfully.
- Piping the guest bootstrap into Bash repeated the same real download and
  reported the exact pinned runtime already installed. All runtime hashes matched
  the first installation.
- Before/after hashes of SSH/UFW/default-policy files, Keel configuration/state
  (excluding the mutation lock), and Frank's original authorized_keys matched.
  No security transaction was created and no automatic hardening was performed.
- An EXIT recovery trap restored the original exploratory runtime; a recursive
  comparison matched it exactly afterward.

The positive interactive `--init` path on a supported release remains part of LTS
acceptance. Existing preparation flows were tested separately in the earlier
[UTM failure tests](UTM-failures-2026-11-16.md). Fixture pending-state rejection is
not a claim of exhaustive installation/recovery race coverage.

## Transport and cleanup

The Mac's VPN route captured the VM subnet and the guest's direct GitHub HTTPS
connection timed out. Testing used a process-scoped interface-bound SSH transport
and a temporary VM-loopback SOCKS forward through that authenticated connection.
Only the test process's proxy environment changed. The actual GitHub URL, normal
TLS certificate validation, and pinned checksum were retained; no local payload
substitution was used. No host route, VPN setting, guest network setting or
provider firewall was changed. The proxy was stopped after testing.

The shipping bootstrap still permits only Ubuntu 24.04/26.04, and still requires
explicit fresh-login verification, hardening and confirmation. This remains an
experimental distribution preview, not a stable production release.
