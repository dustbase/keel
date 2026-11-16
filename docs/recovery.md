# Recovery and interrupted execution

Keep the original sessions open and maintain provider console/rescue access.

```bash
sudo keel status
sudo keel rollback
```

`status` reports the active ID, phase, backup path and timer. `rollback` restores
only a pending transaction. It is safe to retry after a failed restoration, once
the underlying storage/service problem is resolved. A successfully committed
transaction cannot be reverted by its old timer; this command is not a general
uninstall or historical configuration rollback.

Each transaction has a versioned, root-private directory under `/var/backups/keel`.
It contains SSH drop-in content/presence, UFW directory and default-policy snapshot,
original UFW activation state, configuration digest, deadline, phase, and a pinned
copy of the runtime. `/var/lib/keel/pending` identifies the active transaction.
Do not delete this file to bypass recovery or verification.

Lifecycle:

```
backing_up -> backed_up -> armed -> applying -> awaiting_confirmation -> committed
                                     |                  |
                                     +-> rolling_back <-+
                                              |
                                   rolled_back / recovery_failed
```

The pending pointer is published after backups complete. Scheduling failure marks
an unmodified transaction aborted and clears its pointer. Before the first
restrictive write, the phase is persisted as applying. Errors and catchable signals
attempt immediate recovery. SIGKILL/connection loss cannot always run a shell trap;
the independent five-minute timer remains armed. The boot-enabled
`keel-recovery.service` handles unfinished transactions on the next boot, including
when the transient timer no longer exists.

Recovery validates/restores SSH, restores the entire UFW directory and
`/etc/default/ufw`, and restores UFW's original enabled/disabled status. If SSH is
not running after reboot, recovery attempts to start it. Failure retains pending
state and backups and returns a failure status; the systemd service can retry.
Use the rescue console if connectivity does not return. Never treat a service
exit or timer existence alone as proof that restoration succeeded.

Confirmation and recovery acquire the same lock. Confirmation checks that its
connection follows completed changes, intent is unchanged and the deadline has
not passed. It persists committed before removing pending state or stopping the
timer. An already-started recovery worker must recheck that decision after locking.

Preparation is a separate additive workflow, not fully rolled back. Its status is
recorded before mutations. Rerun init to complete interrupted package/account/key/
hostname/Tailscale preparation after resolving failures. No original account/key
is removed and automatic reboot is disabled. Do not run another configuration
manager or manually edit SSH/UFW while a transaction is pending.

## Earlier experimental builds

A legacy `/var/lib/keel/pending-rollback` blocks new preparation/installation.
Resolve it with the original installed build before upgrading. The old snapshot
omits UFW default-policy configuration, so the new runtime cannot safely invent
that missing original policy. With console access, inspect the old snapshot and
restore/verify SSH, `/etc/ufw`, `/etc/default/ufw`, and original activation state.
Only after recovery is actually verified should the legacy marker be archived.
The new runtime reports this condition explicitly rather than silently clearing it.
