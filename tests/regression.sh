#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2317
# Functions override imported dependencies in isolated test processes.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/common.sh
source lib/common.sh
# shellcheck source=lib/keys.sh
source lib/keys.sh
# shellcheck source=lib/session.sh
source lib/session.sh
# shellcheck source=lib/ssh.sh
source lib/ssh.sh
# shellcheck source=lib/transaction.sh
source lib/transaction.sh
# shellcheck source=lib/security.sh
source lib/security.sh
cases=(entrypoint config keys key_staging boundary verify_boundary openssh_evidence tailscale_evidence tailscale_pty digest_locale ssh_checks listener firewall_preflight \
  backup_restore scheduling partial_apply confirmation rollback_failure rollback_race interruption stale_verification public_port concurrency)
if [[ "${1:-}" == --list ]]; then printf '%s\n' "${cases[@]}"; exit 0; fi
scratch="$(mktemp -d)"
trap 'command rm -rf "$scratch"' EXIT
KEEL_HOME="$PWD"
KEEL_STATE="$scratch/state"
KEEL_BACKUP="$scratch/backups"
KEEL_CONFIG="$scratch/config"
KEEL_SSH_DROPIN="$scratch/ssh.conf"
mkdir -p "$KEEL_STATE" "$KEEL_BACKUP"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "Expected [$2], received [$1]"; }
expect_fail() { if ( "$@" ); then fail "Unexpected success: $*"; fi; }
fixture_config() {
  KEEL_LOCAL_PORT=2222
  KEEL_HOST=node KEEL_ADMIN=admin KEEL_TS=no KEEL_TS_MODE=openssh KEEL_PROFILE=private KEEL_CUSTOM=''
  keel_save_config
}
mock_trust() { keel_trusted_path() { [[ -e "$1" && ! -L "$1" ]]; }; }
# These test-only shims map every hardcoded UFW path into the private fixture.
# No root command is executed, even if the suite is accidentally invoked as root.
mock_host() {
  mock_trust
  mkdir -p "$scratch/etc/ufw" "$scratch/etc/default"
  printf 'DEFAULT_INPUT_POLICY="ACCEPT"\nDEFAULT_OUTPUT_POLICY="DROP"\nIPV6=yes\n' > "$scratch/etc/default/ufw"
  printf 'original rule\n' > "$scratch/etc/ufw/user.rules"
  printf 'original ssh\n' > "$KEEL_SSH_DROPIN"
  printf 'active\n' > "$scratch/ufw-state"
  cp() {
    local arg
    local -a args=()
    for arg in "$@"; do
      case "$arg" in /etc/ufw|/etc/default/ufw) arg="$scratch${arg}" ;; esac
      args+=("$arg")
    done
    command cp "${args[@]}"
  }
  rm() {
    local arg
    local -a args=()
    for arg in "$@"; do
      case "$arg" in /etc/ufw) arg="$scratch${arg}" ;; /etc/*) fail 'Unexpected host deletion' ;; esac
      args+=("$arg")
    done
    command rm "${args[@]}"
  }
  keel_ufw() {
    case "$*" in
      status) printf 'Status: %s\n' "$(cat "$scratch/ufw-state")" ;;
      '--force disable') echo inactive > "$scratch/ufw-state" ;;
      '--force enable') echo active > "$scratch/ufw-state" ;;
      *) fail "Unexpected UFW command: $*" ;;
    esac
  }
  keel_sshd() { return 0; }
  keel_systemctl() { printf '%s\n' "$*" >> "$scratch/systemctl"; }
}
test_entrypoint() {
  mkdir -p "$scratch/bin"
  ln -s "$PWD/bin/keel" "$scratch/first"
  ln -s ../first "$scratch/bin/keel"
  bash "$scratch/bin/keel" help | grep -q 'Keel'
  local output
  output="$(bash "$scratch/bin/keel" help)"
  [[ "$output" == *'rollback'* ]] || fail 'Installed entrypoint did not load modules.'
}
test_config() {
  fixture_config
  keel_parse_config < "$KEEL_CONFIG"
  assert_eq "$KEEL_ADMIN" admin
  # shellcheck disable=SC2016 # Deliberately hostile data must never execute.
  printf 'KEEL_ADMIN=$(touch %s)\n' "$scratch/executed" >> "$KEEL_CONFIG"
  expect_fail keel_parse_config < "$KEEL_CONFIG"
  [[ ! -e "$scratch/executed" ]] || fail 'Config executed shell.'
  fixture_config
  sed -i 's/KEEL_ADMIN=admin/KEEL_ADMIN=root/' "$KEEL_CONFIG"
  expect_fail keel_parse_config < "$KEEL_CONFIG"
  expect_fail keel_valid_rules '0/tcp'
  expect_fail keel_valid_rules '65536/udp'
  expect_fail keel_valid_rules '22/tcp;id'
  expect_fail keel_valid_rules '9999999999999999999999/tcp'
  keel_valid_rules '2222/tcp,51820/udp'
  KEEL_CUSTOM='' KEEL_PROFILE=custom
  expect_fail keel_validate_config
  mock_trust
  fixture_config
  keel_load_config
  mv "$KEEL_CONFIG" "$scratch/real-config"
  ln -s "$scratch/real-config" "$KEEL_CONFIG"
  expect_fail keel_load_config
  getent() {
    case "$2" in
      root-alias) echo 'root-alias:x:0:0:root:/root:/bin/bash' ;;
      service) echo 'service:x:100:100:service:/var/lib/service:/bin/bash' ;;
      normal) echo 'normal:x:1000:1000:normal:/home/normal:/bin/bash' ;;
      *) return 2 ;;
    esac
  }
  expect_fail keel_existing_admin_safe root-alias
  expect_fail keel_existing_admin_safe service
  keel_existing_admin_safe normal
  keel_existing_admin_safe new-account
}
test_keys() {
  ssh-keygen -q -t ed25519 -N '' -C original -f "$scratch/one"
  ssh-keygen -q -t ed25519 -N '' -C second -f "$scratch/two"
  local first second restricted
  first="$(cat "$scratch/one.pub")"; second="$(cat "$scratch/two.pub")"
  restricted="command=\"echo hello world\",no-port-forwarding $first"
  keel_valid_key "$restricted"
  expect_fail keel_valid_key "$(cat "$scratch/one")"
  expect_fail keel_valid_key 'ssh-ed25519 not-a-key'
  expect_fail keel_valid_key '# comment only'
  expect_fail keel_valid_key "$first"$'\n'"$second"
  printf '%s' "$first" > "$scratch/authorized_keys"
  keel_append_key "$scratch/authorized_keys" "$second"
  assert_eq "$(ssh-keygen -lf "$scratch/authorized_keys" | wc -l)" 2
  keel_append_key "$scratch/authorized_keys" "$second"
  assert_eq "$(wc -l < "$scratch/authorized_keys")" 2
  keel_append_key "$scratch/authorized_keys" "$restricted"
  grep -Fqx "$restricted" "$scratch/authorized_keys"
  printf '# comment only\n' > "$scratch/comments"
  expect_fail keel_has_keys "$scratch/comments"
}
test_key_staging() {
  mkdir -p "$scratch/homes/original" "$scratch/homes/admin" "$scratch/key-tmp"
  getent() {
    [[ "$1" == passwd && "$2" =~ ^(original|admin)$ ]] || return 2
    printf '%s:x:1000:1000::%s:/bin/bash\n' "$2" "$scratch/homes/$2"
  }
  runuser() {
    [[ "$1" == -u && "$3" == -- ]] || return 1
    shift 3
    command "$@"
  }
  mktemp() {
    local count=0
    [[ ! -f "$scratch/allocations" ]] || read -r count < "$scratch/allocations"
    (( count += 1 ))
    printf '%s\n' "$count" > "$scratch/allocations"
    if [[ -f "$scratch/fail-second" && "$count" == 2 ]]; then return 1; fi
    command mktemp "$scratch/key-tmp/entry.XXXXXX"
  }
  # Empty input refuses preparation without leaving either staging file behind.
  expect_fail keel_keys_setup original admin < /dev/null
  [[ -z "$(find "$scratch/key-tmp" -mindepth 1 -print -quit)" ]] || fail 'Aborted key entry leaked staging files.'
  # A failed second allocation must also clean up the first file.
  printf '0\n' > "$scratch/allocations"
  touch "$scratch/fail-second"
  expect_fail keel_keys_setup original admin < /dev/null
  [[ -z "$(find "$scratch/key-tmp" -mindepth 1 -print -quit)" ]] || fail 'Allocation failure leaked staging files.'
}
test_boundary() {
  fixture_config
  keel_boot_id() { echo boot-A; }
  keel_ticks() { echo 1000; }
  keel_record_boundary > "$scratch/boundary"
  KEEL_CONNECTION_START=1001
  keel_after_boundary "$scratch/boundary"
  KEEL_CONNECTION_START=1000
  expect_fail keel_after_boundary "$scratch/boundary"
  KEEL_CONNECTION_START=999
  expect_fail keel_after_boundary "$scratch/boundary"
  KEEL_CONNECTION_START=1001
  printf '\n' >> "$KEEL_CONFIG"
  expect_fail keel_after_boundary "$scratch/boundary"
  fixture_config
  keel_boot_id() { echo boot-B; }
  expect_fail keel_after_boundary "$scratch/boundary"
}
test_verify_boundary() {
  fixture_config
  keel_boot_id() { echo boot-A; }
  keel_ticks() { echo 200; }
  local connection=100 digest
  digest="$(keel_config_digest)"
  keel_verify_identity() { KEEL_CONNECTION_START="$connection"; KEEL_CONNECTION_ID=conn; }
  keel_init() { fail 'Verification attempted to rerun preparation.'; }
  printf 'boot-A 100 %s\n' "$digest" > "$KEEL_STATE/prepared"
  if ( keel_verify ) > "$scratch/error" 2>&1; then fail 'Same-boundary connection verified.'; fi
  grep -q 'SSH connection predates' "$scratch/error"
  grep -q 'Do not rerun init solely' "$scratch/error"
  grep -q 'ssh -o ControlMaster=no -o ControlPath=none -p 2222 admin@node' "$scratch/error"
  grep -q '    keel verify$' "$scratch/error"
  [[ ! -e "$KEEL_STATE/verified" ]] || fail 'Old connection wrote verification.'
  connection=99
  expect_fail keel_verify
  connection=101
  keel_verify
  [[ -s "$KEEL_STATE/verified" ]] || fail 'Fresh connection did not verify.'
  rm "$KEEL_STATE/verified"
  printf 'boot-A 100 changed-intent\n' > "$KEEL_STATE/prepared"
  if ( keel_verify ) > "$scratch/error" 2>&1; then fail 'Changed intent verified.'; fi
  grep -q 'Prepared settings differ' "$scratch/error"
  printf 'boot-B 100 %s\n' "$digest" > "$KEEL_STATE/prepared"
  if ( keel_verify ) > "$scratch/error" 2>&1; then fail 'Prior-boot preparation verified.'; fi
  grep -q 'different boot' "$scratch/error"
  printf 'boot-A invalid %s\n' "$digest" > "$KEEL_STATE/prepared"
  if ( keel_verify ) > "$scratch/error" 2>&1; then fail 'Malformed preparation verified.'; fi
  grep -q 'evidence is malformed' "$scratch/error"
  rm "$KEEL_STATE/prepared"
  if ( keel_verify ) > "$scratch/error" 2>&1; then fail 'Missing preparation verified.'; fi
  grep -q 'No completed preparation' "$scratch/error"
  [[ ! -e "$KEEL_STATE/verified" ]] || fail 'Invalid preparation wrote verification.'
  assert_eq "$(keel_config_digest)" "$digest"
  keel_tailscale_status_json() { return 1; }
  KEEL_LOCAL_IP=2001:db8::2 KEEL_LOCAL_PORT=22 KEEL_TS=yes
  keel_reconnect_help confirm > "$scratch/reconnect"
  grep -q 'admin@2001:db8::2' "$scratch/reconnect"
  grep -q '    keel confirm$' "$scratch/reconnect"
  if grep -q -- '-p 22' "$scratch/reconnect"; then fail 'Unnecessary default port in reconnect command.'; fi
}
test_openssh_evidence() {
  KEEL_ADMIN="admin"
  ss() { echo '0 0 203.0.113.2:2222 198.51.100.1:43210 users:(("sshd",pid=80,fd=4))'; }
  journalctl() {
    printf '%s\n' "$*" > "$scratch/journal-query"
    cat "$scratch/journal"
  }
  keel_proc_start() { echo 700; }
  printf '%s\n' '{"MESSAGE":"Accepted publickey for admin from 198.51.100.1 port 43210 ssh2: ED25519 SHA256:abc","__MONOTONIC_TIMESTAMP":"8000000"}' > "$scratch/journal"
  keel_openssh_evidence 80 /usr/sbin/sshd
  assert_eq "$KEEL_LOCAL_PORT" 2222
  grep -q '_PID=80 _UID=0 _EXE=/usr/sbin/sshd' "$scratch/journal-query"
  printf '%s\n' '{"MESSAGE":"Accepted password for admin from 198.51.100.1 port 43210 ssh2","__MONOTONIC_TIMESTAMP":"8000000"}' > "$scratch/journal"
  # shellcheck disable=SC2034 # Forged input deliberately has no effect.
  KEEL_SESSION='198.51.100.1 43210 203.0.113.2 2222'
  expect_fail keel_openssh_evidence 80 /usr/sbin/sshd
  printf '%s\n' '{"MESSAGE":"Accepted publickey for another from 198.51.100.1 port 43210 ssh2: ED25519 SHA256:abc","__MONOTONIC_TIMESTAMP":"8000000"}' > "$scratch/journal"
  expect_fail keel_openssh_evidence 80 /usr/sbin/sshd
  printf '%s\n' '{"MESSAGE":"Accepted publickey for admin from 198.51.100.1 port 43211 ssh2: ED25519 SHA256:abc","__MONOTONIC_TIMESTAMP":"8000000"}' > "$scratch/journal"
  expect_fail keel_openssh_evidence 80 /usr/sbin/sshd
  expect_fail keel_openssh_evidence 81 /usr/sbin/sshd
  printf '%s\n' '{"MESSAGE":"Accepted publickey for admin from 198.51.100.1 port 43210 ssh2: ED25519 SHA256:abc","__MONOTONIC_TIMESTAMP":"1000"}' > "$scratch/journal"
  expect_fail keel_openssh_evidence 80 /usr/sbin/sshd
}
test_tailscale_evidence() {
  # Exercise the actual journal parser separately from privileged /proc ancestry.
  local result
  result="$(printf '%s\n' '{"MESSAGE":"ssh-conn-20261114T120000-aabb: handling conn: 100.64.0.1:43210->admin@100.64.0.2:22","__MONOTONIC_TIMESTAMP":"1000000"}' \
    '{"MESSAGE":"ssh-conn-20261114T120100-aacc: handling conn: 100.64.0.1:43210->admin@100.64.0.2:22","__MONOTONIC_TIMESTAMP":"3000000"}' |
    keel_tailscale_journal ': handling conn: 100.64.0.1:43210->admin@100.64.0.2:22' 100)"
  assert_eq "$result" 'ssh-conn-20261114T120000-aabb 100'
  result="$(printf '%s\n' '{"MESSAGE":"access granted","__MONOTONIC_TIMESTAMP":"1000000"}' |
    keel_tailscale_journal ': handling conn: 100.64.0.1:43210->admin@100.64.0.2:22' 100)"
  assert_eq "$result" ''
  result="$(printf '%s\n' '{"MESSAGE":"ssh-conn-20261114T120000-aabb: handling conn: [fd7a:115c:a1e0::1]:43210->admin@[fd7a:115c:a1e0::2]:22","__MONOTONIC_TIMESTAMP":"2000000"}' |
    keel_tailscale_journal ': handling conn: [fd7a:115c:a1e0::1]:43210->admin@[fd7a:115c:a1e0::2]:22' 100)"
  assert_eq "$result" 'ssh-conn-20261114T120000-aabb 200'
  expect_fail keel_tailscale_evidence "$BASHPID"
  mkdir -p "$scratch/bin"
  printf '#!/bin/sh\nexit 1\n' > "$scratch/bin/tailscaled"
  chmod 755 "$scratch/bin/tailscaled"
  PATH="$scratch/bin:$PATH"
  mock_trust
  KEEL_ADMIN="admin"
  local monitor_mode=no ssh_enabled=yes helper_kind=login
  keel_proc_exe() {
    if [[ "$1" == 100 && "$helper_kind" == login ]]; then echo /usr/bin/login; else echo "$scratch/bin/tailscaled"; fi
  }
  keel_proc_parent() {
    if [[ "$1" == 100 && "$monitor_mode" == yes ]]; then echo 300; else echo 200; fi
  }
  keel_proc_root() { return 0; }
  keel_proc_args() {
    if [[ "$1" == 100 && "$helper_kind" == ssh ]]; then printf '%s\0' tailscaled be-child ssh --local-user=admin
    elif [[ "$1" == 300 ]]; then printf '%s\0' tailscaled be-child ssh-monitor --local-user=admin
    else printf '%s\0' tailscaled; fi
  }
  keel_proc_environment() { printf '%s\0' 'SSH_CONNECTION=100.64.0.1 43210 100.64.0.2 22'; }
  keel_proc_start() { if [[ "$1" == 200 ]]; then echo 100; else echo 1100; fi; }
  keel_systemctl() { echo 200; }
  keel_is_tailscale_ip() { [[ "$1" == 100.64.0.2 ]]; }
  tailscale() { if [[ "$ssh_enabled" == yes ]]; then echo '{"RunSSH":true}'; else echo '{"RunSSH":false}'; fi; }
  journalctl() { echo '{"MESSAGE":"ssh-conn-20261114T120000-aabb: handling conn: 100.64.0.1:43210->admin@100.64.0.2:22","__MONOTONIC_TIMESTAMP":"10000000"}'; }
  keel_tailscale_evidence 100
  assert_eq "$KEEL_CONNECTION_START" 1000
  assert_eq "$KEEL_LOCAL_PORT" 22
  monitor_mode=yes
  keel_tailscale_evidence 100
  helper_kind=ssh
  keel_tailscale_evidence 100
  # Observed Tailscale 1.104.7 layout: the ssh helper has dropped to the
  # administrator UID, beneath a root ssh-monitor. Its environment is not proof.
  keel_proc_root() { [[ "$1" != 100 ]]; }
  expect_fail keel_tailscale_evidence 100
  keel_proc_root() { return 0; }
  helper_kind=login
  ssh_enabled=no
  expect_fail keel_tailscale_evidence 100
  ssh_enabled=yes
  keel_systemctl() { echo 201; }
  expect_fail keel_tailscale_evidence 100
}
test_firewall_preflight() {
  keel_systemctl() { return 1; }
  keel_security_digest() { echo baseline; }
  keel_ufw() { cat "$scratch/added"; }
  printf 'IPV6=yes\n' > "$scratch/ufw-default"
  grep() {
    local arg
    local -a args=()
    for arg in "$@"; do
      [[ "$arg" != /etc/default/ufw ]] || arg="$scratch/ufw-default"
      args+=("$arg")
    done
    command grep "${args[@]}"
  }
  : > "$scratch/added"
  keel_firewall_preflight
  echo 'ufw allow 22/tcp' > "$scratch/added"
  expect_fail keel_firewall_preflight
  echo baseline > "$KEEL_STATE/managed-firewall"
  echo "public 22/tcp" > "$KEEL_STATE/managed-rules"
  keel_firewall_preflight
  echo changed > "$KEEL_STATE/managed-firewall"
  expect_fail keel_firewall_preflight
  : > "$scratch/added"
  echo 'IPV6=no' > "$scratch/ufw-default"
  expect_fail keel_firewall_preflight
  keel_systemctl() { return 0; }
  expect_fail keel_firewall_preflight
}
test_ssh_checks() {
  keel_effective_hardened $'PermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes'
  expect_fail keel_effective_hardened $'PermitRootLogin no\nPasswordAuthentication yes\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes'
  expect_fail keel_effective_hardened $'PermitRootLogin no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes'
  printf 'Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication yes\n' | keel_ssh_layout_file /etc/ssh/sshd_config
  expect_fail keel_ssh_layout_file /etc/ssh/sshd_config <<< 'Match User admin'
  expect_fail keel_ssh_layout_file /etc/ssh/sshd_config <<< 'Match=User admin'
  expect_fail keel_ssh_layout_file /etc/ssh/sshd_config <<< 'Include=/tmp/unmanaged'
  expect_fail keel_ssh_layout_file /etc/ssh/sshd_config.d/custom.conf <<< 'Include /etc/ssh/sshd_config.d/*.conf'
  fixture_config
  keel_ssh_preflight() { return 0; }
  KEEL_REMOTE_IP=198.51.100.1 KEEL_LOCAL_IP=203.0.113.2 KEEL_LOCAL_PORT=2222
  keel_sshd() {
    printf '%s\n' "$*" >> "$scratch/sshd-calls"
    [[ "$*" != -t ]] || return 0
    printf '%s\n' 'permitrootlogin no' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes'
    [[ "$*" != *'user=admin,'* ]] || cat "$scratch/match-setting"
  }
  : > "$scratch/match-setting"
  keel_ssh_check
  grep -q -- '-T -C user=admin,addr=198.51.100.1' "$scratch/sshd-calls"
  # Replacement output models a Match override, not two contradictory lines.
  keel_sshd() {
    [[ "$*" != -t ]] || return 0
    printf '%s\n' 'permitrootlogin no' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes'
    if [[ "$*" == *'user=admin,'* ]]; then echo 'passwordauthentication yes'; else echo 'passwordauthentication no'; fi
  }
  expect_fail keel_ssh_check
}
test_listener() {
  KEEL_LOCAL_PORT=2222
  ss() { echo 'LISTEN 0 4096 [::]:2222 [::]:*'; }
  keel_listener_check
  ss() { echo 'LISTEN 0 4096 0.0.0.0:2222 0.0.0.0:*'; }
  keel_listener_check
  KEEL_LOCAL_PORT=22
  expect_fail keel_listener_check
  ss() { echo 'LISTEN 0 22 127.0.0.53:53 0.0.0.0:*'; }
  expect_fail keel_listener_check
  ss() { echo 'ESTAB 0 0 192.0.2.1:22 192.0.2.2:54321'; }
  expect_fail keel_listener_check
  keel_endpoint '[2001:db8::1]:2222' KEEL_LOCAL
  assert_eq "$KEEL_LOCAL_IP" 2001:db8::1
  assert_eq "$KEEL_LOCAL_PORT" 2222
  keel_endpoint '[::ffff:203.0.113.2]:2222' KEEL_LOCAL
  assert_eq "$KEEL_LOCAL_IP" 203.0.113.2
}
test_backup_restore() {
  fixture_config
  mock_host
  keel_backup_security
  assert_eq "$(cat "$KEEL_TX/phase")" backed_up
  cmp "$KEEL_TX/ufw-default" "$scratch/etc/default/ufw"
  [[ -f "$KEEL_TX/runtime/bin/keel" ]] || fail 'Missing pinned recovery.'
  keel_transaction_phase applying
  echo changed > "$scratch/etc/default/ufw"
  echo changed > "$scratch/etc/ufw/user.rules"
  echo new > "$scratch/etc/ufw/extra.rules"
  echo changed > "$KEEL_SSH_DROPIN"
  keel_rollback
  assert_eq "$(cat "$KEEL_TX/phase")" rolled_back
  grep -q 'DEFAULT_OUTPUT_POLICY="DROP"' "$scratch/etc/default/ufw"
  assert_eq "$(cat "$scratch/etc/ufw/user.rules")" 'original rule'
  assert_eq "$(cat "$KEEL_SSH_DROPIN")" 'original ssh'
  [[ ! -e "$scratch/etc/ufw/extra.rules" && ! -e "$KEEL_STATE/pending" ]] || fail 'Incomplete restoration.'
  # Originally absent SSH file and inactive firewall remain absent/inactive.
  command rm "$KEEL_SSH_DROPIN"
  echo inactive > "$scratch/ufw-state"
  keel_backup_security
  keel_transaction_phase applying
  echo changed > "$KEEL_SSH_DROPIN"
  keel_rollback
  [[ ! -e "$KEEL_SSH_DROPIN" ]] || fail 'Restored absent file incorrectly.'
  assert_eq "$(cat "$scratch/ufw-state")" inactive
}
test_scheduling() {
  fixture_config
  mock_host
  keel_backup_security
  systemd-run() { return 1; }
  expect_fail keel_schedule_rollback
  keel_abort_unarmed
  [[ ! -e "$KEEL_STATE/pending" ]] || fail 'Failed scheduling left pending state.'
  assert_eq "$(cat "$KEEL_TX/phase")" aborted
  keel_backup_security
  systemd-run() { return 0; }
  keel_systemctl() { [[ "$1" != is-active ]]; }
  expect_fail keel_schedule_rollback
  keel_abort_unarmed
  [[ ! -e "$KEEL_STATE/pending" ]] || fail 'Unverified timer left pending state.'
}
secure_fixture() {
  fixture_config
  KEEL_CONNECTION_ID=conn-1 KEEL_LOCAL_PORT=2222 KEEL_LOCAL_IP=203.0.113.2 KEEL_REMOTE_IP=198.51.100.1
  keel_verify_identity() { return 0; }
  keel_ticks() { echo 1000; }
  keel_atomic_write "$KEEL_STATE/verified" "$(keel_boot_id) 900 $(keel_config_digest) conn-1 2222"
  keel_ssh_preflight() { return 0; }
  keel_listener_check() { return 0; }
  keel_firewall_preflight() { return 0; }
  keel_yes() { return 0; }
}
test_partial_apply() {
  secure_fixture
  mock_host
  keel_schedule_rollback() { keel_transaction_phase armed; }
  keel_apply_security() { echo changed > "$KEEL_SSH_DROPIN"; return 1; }
  expect_fail keel_secure
  [[ ! -e "$KEEL_STATE/pending" ]] || fail 'Apply failure left recoverable state uncleared.'
  assert_eq "$(cat "$KEEL_SSH_DROPIN")" 'original ssh'
}
confirm_fixture() {
  fixture_config
  mock_trust
  KEEL_TX_ID=123-456-789 KEEL_TX="$KEEL_BACKUP/123-456-789"
  mkdir -p "$KEEL_TX"
  keel_atomic_write "$KEEL_STATE/pending" "$KEEL_TX_ID"
  keel_atomic_write "$KEEL_TX/version" 1
  keel_transaction_phase awaiting_confirmation
  keel_boot_id > "$KEEL_TX/boot"
  echo 2222 > "$KEEL_TX/management-port"
  echo 2000 > "$KEEL_TX/deadline"
  keel_ticks() { echo 1000; }
  keel_record_boundary > "$KEEL_TX/applied-boundary"
  KEEL_CONNECTION_START=1001
  echo baseline > "$KEEL_TX/applied-digest"
  keel_verify_identity() { return 0; }
  keel_ssh_check() { return 0; }
  keel_security_digest() { echo baseline; }
  keel_systemctl() { return 0; }
}
test_confirmation() {
  confirm_fixture
  KEEL_CONNECTION_START=900
  expect_fail keel_confirm
  [[ -f "$KEEL_STATE/pending" ]] || fail 'Old session cancelled recovery.'
  KEEL_CONNECTION_START=1001
  printf '\n' >> "$KEEL_CONFIG"
  expect_fail keel_confirm
  fixture_config
  echo 999 > "$KEEL_TX/deadline"
  expect_fail keel_confirm
  echo 2000 > "$KEEL_TX/deadline"
  keel_confirm
  assert_eq "$(cat "$KEEL_TX/phase")" committed
  [[ ! -f "$KEEL_STATE/pending" ]] || fail 'Confirmation left pending.'
}
test_rollback_failure() {
  fixture_config
  mock_host
  keel_backup_security
  keel_transaction_phase applying
  keel_sshd() { return 1; }
  expect_fail keel_rollback
  [[ -f "$KEEL_STATE/pending" ]] || fail 'Failed recovery discarded evidence.'
  assert_eq "$(cat "$KEEL_TX/phase")" recovery_failed
  keel_sshd() { return 0; }
  keel_rollback
  [[ ! -f "$KEEL_STATE/pending" ]] || fail 'Recovery retry did not clear state.'
}
test_rollback_race() {
  confirm_fixture
  keel_transaction_phase committed
  keel_restore_security() { fail 'Committed transaction was rolled back.'; }
  keel_rollback
  [[ ! -f "$KEEL_STATE/pending" ]] || fail 'Terminal decision not cleaned up.'
  confirm_fixture
  keel_rollback 999-888-777
  [[ -f "$KEEL_STATE/pending" ]] || fail 'Old timer affected new transaction.'
}
test_interruption() {
  fixture_config
  mock_host
  keel_backup_security
  keel_transaction_phase applying
  echo changed > "$KEEL_SSH_DROPIN"
  local rc=0
  (
    trap 'keel_transaction_exit $?' EXIT
    trap 'exit 143' TERM
    kill -TERM "$BASHPID"
  ) || rc=$?
  assert_eq "$rc" 143
  assert_eq "$(cat "$KEEL_TX/phase")" rolled_back
  assert_eq "$(cat "$KEEL_SSH_DROPIN")" 'original ssh'
}
test_stale_verification() {
  secure_fixture
  KEEL_CONNECTION_ID=conn-2
  keel_backup_security() { fail 'Stale verification reached backup.'; }
  expect_fail keel_secure
  KEEL_CONNECTION_ID=conn-1
  printf '\n' >> "$KEEL_CONFIG"
  expect_fail keel_secure
}
test_public_port() {
  secure_fixture
  keel_write_ssh() { return 0; }
  keel_ssh_check() { return 0; }
  keel_systemctl() { return 0; }
  keel_ufw() {
    printf '%s\n' "$*" >> "$scratch/ufw-commands"
    [[ "$1" != status ]] || echo 'Status: active'
  }
  keel_apply_security
  grep -qx 'allow 2222/tcp' "$scratch/ufw-commands"
  if grep -qx 'allow 22/tcp' "$scratch/ufw-commands"; then fail 'Wrong public SSH port opened.'; fi
  # Switching a known web profile to private removes old public web/SSH rules.
  printf 'public 80/tcp\npublic 443/tcp\npublic 22/tcp\n' > "$KEEL_STATE/managed-rules"
  : > "$scratch/ufw-commands"
  keel_apply_security
  grep -qx -- '--force delete allow 80/tcp' "$scratch/ufw-commands"
  grep -qx -- '--force delete allow 443/tcp' "$scratch/ufw-commands"
  grep -qx -- '--force delete allow 22/tcp' "$scratch/ufw-commands"
  local add_line delete_line
  add_line="$(grep -n '^allow 2222/tcp$' "$scratch/ufw-commands" | cut -d: -f1)"
  delete_line="$(grep -n '^--force delete allow 22/tcp$' "$scratch/ufw-commands" | cut -d: -f1)"
  (( add_line < delete_line ))
  expect_fail keel_ufw_rule delete public '22/tcp;id'
  KEEL_PROFILE=custom KEEL_CUSTOM=00022/tcp
  assert_eq "$(keel_desired_rules)" "$(printf 'public 22/tcp\npublic 2222/tcp')"
  KEEL_PROFILE=private KEEL_CUSTOM=''
  KEEL_TS=yes
  : > "$scratch/ufw-commands"
  keel_apply_security
  grep -qx 'allow in on tailscale0 to any port 2222 proto tcp' "$scratch/ufw-commands"
}
test_concurrency() {
  # Real flock, no host state: a second mutator cannot enter until release.
  local fd
  exec {fd}>"$scratch/lock"
  flock -n "$fd"
  if bash -c 'exec 9>"$1"; flock -n 9' bash "$scratch/lock"; then fail 'Concurrent lock succeeded.'; fi
  exec {fd}>&-
  bash -c 'exec 9>"$1"; flock -n 9' bash "$scratch/lock"
}
test_tailscale_pty() {
  fixture_config
  KEEL_ADMIN='admin'
  id() { if [[ "$*" == '-u admin' ]]; then echo 1000; else command id "$@"; fi; }
  keel_proc_root() { [[ "$1" == 100 ]]; }
  keel_proc_cgroup() { echo '0::/user.slice/user-1000.slice/session-61.scope'; }
  keel_loginctl() { cat "$scratch/logind"; }
  local metadata
  metadata=$'Id=61\nLeader=100\nUser=1000\nName=admin\nTTY=pts/3\nRemote=yes\nRemoteHost=100.64.0.1\nService=remote\nType=tty\nClass=user\nScope=session-61.scope'
  printf '%s\n' "$metadata" > "$scratch/logind"
  SSH_CONNECTION='203.0.113.1 1 203.0.113.2 22' keel_tailscale_login_tty 100
  assert_eq "$KEEL_LOGIN_TTY" pts/3
  assert_eq "$KEEL_LOGIN_REMOTE" 100.64.0.1
  expect_fail keel_tailscale_login_tty 101
  local pair key
  for pair in Leader=101 User=1001 Name=other TTY=tty1 Remote=no Service=login Type=unspecified Class=manager Scope=session-62.scope; do
    key="${pair%%=*}"
    printf '%s\n' "$metadata" | sed "s/^$key=.*/$pair/" > "$scratch/logind"
    expect_fail keel_tailscale_login_tty 100
  done
  printf '%s\nLeader=100\n' "$metadata" > "$scratch/logind"
  expect_fail keel_tailscale_login_tty 100
  printf '%s\n' "$metadata" > "$scratch/logind"
  keel_proc_cgroup() { echo '0::/user.slice/user-1000.slice/session-../61.scope'; }
  expect_fail keel_tailscale_login_tty 100

  cat > "$scratch/pty-journal" <<'JSON'
{"MESSAGE":"ssh-conn-20261114T120000-aabb: handling conn: 100.64.0.1:43210->admin@100.64.0.2:22","__MONOTONIC_TIMESTAMP":"10000000"}
{"MESSAGE":"ssh-conn-20261114T120000-aabb: starting session: sess-20261114T120001-aacc","__MONOTONIC_TIMESTAMP":"10900000"}
{"MESSAGE":"ssh-session(sess-20261114T120001-aacc): starting pty command via session monitor: [/usr/sbin/tailscaled be-child ssh --uid=1000 --local-user=admin --has-tty=true --tty-name=pts/3 --shell --env-fd=3]","__MONOTONIC_TIMESTAMP":"11000000"}
JSON
  local result expected
  expected='ssh-conn-20261114T120000-aabb 1000 100.64.0.1:43210 100.64.0.2:22'
  result="$(keel_tailscale_pty_journal pts/3 admin 1000 /usr/sbin/tailscaled 1101 100 < "$scratch/pty-journal")"
  assert_eq "$result" "$expected"
  expect_fail keel_tailscale_pty_journal pts/4 admin 1000 /usr/sbin/tailscaled 1101 100 < "$scratch/pty-journal"
  expect_fail keel_tailscale_pty_journal pts/3 other 1000 /usr/sbin/tailscaled 1101 100 < "$scratch/pty-journal"
  expect_fail keel_tailscale_pty_journal pts/3 admin 1001 /usr/sbin/tailscaled 1101 100 < "$scratch/pty-journal"
  expect_fail keel_tailscale_pty_journal pts/3 admin 1000 /usr/sbin/tailscaled 2000 100 < "$scratch/pty-journal"
  head -2 "$scratch/pty-journal" > "$scratch/pty-invalid"
  expect_fail keel_tailscale_pty_journal pts/3 admin 1000 /usr/sbin/tailscaled 1101 100 < "$scratch/pty-invalid"
  # A root log containing client-command text cannot masquerade as a shell launch.
  sed 's/ --shell/ --cmd=echo --shell/' "$scratch/pty-journal" > "$scratch/pty-invalid"
  expect_fail keel_tailscale_pty_journal pts/3 admin 1000 /usr/sbin/tailscaled 1101 100 < "$scratch/pty-invalid"
  sed 's/--tty-name=pts\/3/--tty-name=pts\/4 --tty-name=pts\/3/' "$scratch/pty-journal" > "$scratch/pty-invalid"
  expect_fail keel_tailscale_pty_journal pts/3 admin 1000 /usr/sbin/tailscaled 1101 100 < "$scratch/pty-invalid"
  cat "$scratch/pty-journal" "$scratch/pty-journal" > "$scratch/pty-invalid"
  expect_fail keel_tailscale_pty_journal pts/3 admin 1000 /usr/sbin/tailscaled 1101 100 < "$scratch/pty-invalid"
  # A later multiplexed session retains its ORIGINAL connection authentication age.
  sed -e 's/10900000/49900000/' -e 's/11000000/50000000/' "$scratch/pty-journal" > "$scratch/pty-mux"
  result="$(keel_tailscale_pty_journal pts/3 admin 1000 /usr/sbin/tailscaled 5001 100 < "$scratch/pty-mux")"
  assert_eq "$result" "$expected"
  KEEL_CONNECTION_START=1000
  keel_boot_id() { echo fixture-boot; }
  printf 'fixture-boot 4000 %s\n' "$(keel_config_digest)" > "$scratch/applied-boundary"
  expect_fail keel_after_boundary "$scratch/applied-boundary"
}
test_digest_locale() {
  printf 'fixture\n' > "$KEEL_SSH_DROPIN"
  # Isolate enumeration/presentation without reading privileged host file bytes.
  sha256sum() {
    if (( $# )); then printf '%s\n' "$1"; else command sha256sum; fi
  }
  keel_ufw() {
    [[ "$LC_ALL" == C && "$COLUMNS" == 80 && "$TERM" == dumb ]] || return 1
    printf 'Status: active\n'
  }
  local first second locale_name=C
  if locale -a | grep -qi '^en_US\.utf8$'; then locale_name=en_US.utf8; fi
  first="$(LC_ALL=C COLUMNS=120 TERM=dumb keel_security_digest)"
  second="$(LC_ALL="$locale_name" COLUMNS=15 TERM=xterm-256color keel_security_digest)"
  assert_eq "$first" "$second"
}
[[ " ${cases[*]} " == *" ${1:-} "* ]] || fail 'Unknown test case.'
"test_$1"
