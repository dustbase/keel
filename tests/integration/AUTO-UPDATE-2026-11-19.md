# Automatic installer update validation — 2026-11-19

The authorized UTM Ubuntu Server guest (Ubuntu 26.10 ARM64, one CPU) passed the
full fixture suite and ShellCheck. New fixtures execute the real Linux atomic
directory-exchange syscall against temporary trees. They check preservation of
the old runtime, pending-recovery and trust/layout refusals, copy/exchange/link
failures, stale-evidence invalidation and fresh-login boundary publication.
SIGKILL immediately before and after the syscall leaves a complete old or new
runtime installed, respectively, with recovery data retained.

A guarded root harness then updated the existing experimental UTM runtime through
the bootstrap using the real public HTTPS archive for runtime
`af69be6f725885391ce215213a9ebe4b334f522b`, with its embedded checksum intact.
Only a guest-local OS guard exception allowed this exploratory 26.10 run; the
shipping bootstrap still permits Ubuntu 24.04/26.04. A temporary SSH-loopback
SOCKS forward preserved normal TLS validation and was stopped after testing.

The automatic upgrade succeeded without moving the old runtime aside manually.
The printed private recovery directory contained an exact copy of the former
runtime after the exchange. Repeating the piped bootstrap reported the pinned
runtime already installed, and installed file hashes matched the first run.
SSH/UFW/default-policy files, configuration, keys and remaining Keel state hashes
were unchanged. Only the expected preparation boundary and verified/secured
markers changed. No preparation, authentication, hardening or confirmation
operation was executed. The harness restored the original UTM runtime and those
evidence markers exactly afterward for subsequent tests.

No real VPS was accessed. These checks do not establish supported-LTS acceptance,
power-loss/reboot behavior across filesystems, or live SSH/security matrix
acceptance. Failed/interrupted update recovery directories are deliberately
retained; inspect their contents rather than assuming a staged status proves
whether the exchange occurred. The updater remains experimental.
