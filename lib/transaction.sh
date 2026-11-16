#!/usr/bin/env bash
# All callers hold the same flock, including timer and boot recovery.
keel_transaction_load() {
  local id
  [[ -f "$KEEL_STATE/pending" ]] || return 1
  read -r id < "$KEEL_STATE/pending" || return 1
  [[ "$id" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] || keel_die 'Invalid transaction ID.'
  KEEL_TX_ID="$id"
  KEEL_TX="$KEEL_BACKUP/$id"
  keel_trusted_path "$KEEL_TX" || keel_die 'Untrusted recovery directory.'
  [[ "$(cat "$KEEL_TX/version")" == 1 ]] || keel_die 'Unsupported transaction format.'
  KEEL_TX_PHASE="$(cat "$KEEL_TX/phase")"
}
keel_transaction_phase() { keel_atomic_write "$KEEL_TX/phase" "$1"; }
keel_install_recovery() {
  local service=/etc/systemd/system/keel-recovery.service
  [[ ! -L "$service" ]] || return 1
  cat > "$service" <<'UNIT'
[Unit]
Description=Recover an unfinished Keel security transaction
After=network.target ssh.service ufw.service tailscaled.service
[Service]
Type=oneshot
ExecStart=/opt/keel/bin/keel __recover-boot
Restart=on-failure
RestartSec=15s
[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 "$service" && keel_systemctl daemon-reload && keel_systemctl enable keel-recovery.service
}
keel_backup_security() {
  KEEL_TX_ID="$(date +%s)-$$-$RANDOM"
  KEEL_TX="$KEEL_BACKUP/$KEEL_TX_ID"
  install -d -m 700 "$KEEL_TX" || return 1
  keel_atomic_write "$KEEL_TX/version" 1 || return 1
  keel_transaction_phase backing_up || return 1
  if [[ -e "$KEEL_SSH_DROPIN" ]]; then
    cp -p "$KEEL_SSH_DROPIN" "$KEEL_TX/ssh-dropin" || return 1
    touch "$KEEL_TX/had-ssh" || return 1
  fi
  cp -a /etc/ufw "$KEEL_TX/ufw" || return 1
  cp -p /etc/default/ufw "$KEEL_TX/ufw-default" || return 1
  local firewall_status
  firewall_status="$(keel_ufw status)" || return 1
  case "$firewall_status" in
    'Status: active'*) touch "$KEEL_TX/ufw-was-active" || return 1 ;;
    'Status: inactive'*) ;;
    *) return 1 ;;
  esac
  install -d -m 700 "$KEEL_TX/runtime/bin" "$KEEL_TX/runtime/lib" || return 1
  install -m 700 "$KEEL_HOME/bin/keel" "$KEEL_TX/runtime/bin/keel" || return 1
  install -m 600 "$KEEL_HOME/lib/"*.sh "$KEEL_TX/runtime/lib/" || return 1
  keel_atomic_write "$KEEL_TX/management-port" "$KEEL_LOCAL_PORT" || return 1
  keel_atomic_write "$KEEL_TX/intent" "$(keel_config_digest)" || return 1
  keel_atomic_write "$KEEL_TX/boot" "$(keel_boot_id)" || return 1
  keel_atomic_write "$KEEL_TX/deadline" "$(( $(keel_ticks) + 300 * $(getconf CLK_TCK) ))" || return 1
  keel_transaction_phase backed_up || return 1
  keel_atomic_write "$KEEL_STATE/pending" "$KEEL_TX_ID"
}
keel_timer_unit() { printf 'keel-rollback-%s' "$KEEL_TX_ID"; }
keel_schedule_rollback() {
  local unit
  unit="$(keel_timer_unit)"
  keel_systemctl is-enabled --quiet keel-recovery.service || return 1
  systemd-run --quiet --unit="$unit" --on-active=5m --timer-property=AccuracySec=1s \
    --property=Restart=on-failure --property=RestartSec=15s \
    "$KEEL_TX/runtime/bin/keel" __rollback "$KEEL_TX_ID" || return 1
  keel_systemctl is-active --quiet "$unit.timer" || return 1
  keel_transaction_phase armed
}
keel_cancel_timer() {
  # A running service waits for our lock and rechecks the terminal phase.
  keel_systemctl stop "$(keel_timer_unit).timer" 2>/dev/null || true
}
keel_abort_unarmed() {
  keel_transaction_phase aborted || return 1
  rm -f "$KEEL_STATE/pending"
  keel_cancel_timer
}
keel_restore_security() {
  local failed=0
  # Restore before clearing evidence; any failure leaves an explicit recovery state.
  if [[ -f "$KEEL_TX/had-ssh" ]]; then
    cp -p "$KEEL_TX/ssh-dropin" "$KEEL_SSH_DROPIN" || failed=1
  else
    rm -f "$KEEL_SSH_DROPIN" || failed=1
  fi
  if keel_sshd -t; then
    if keel_systemctl is-active --quiet ssh.service; then
      keel_systemctl reload ssh.service || failed=1
    else
      keel_systemctl start ssh.service || failed=1
    fi
  else failed=1; fi
  keel_ufw --force disable || failed=1
  # UFW may have created files since backup; replace, don't overlay the snapshot.
  rm -rf /etc/ufw || failed=1
  cp -a "$KEEL_TX/ufw" /etc/ufw || failed=1
  cp -p "$KEEL_TX/ufw-default" /etc/default/ufw || failed=1
  if [[ -f "$KEEL_TX/ufw-was-active" ]]; then
    keel_ufw --force enable || failed=1
    keel_ufw status | grep -q '^Status: active' || failed=1
  else
    keel_ufw status | grep -q '^Status: inactive' || failed=1
  fi
  (( failed == 0 ))
}
keel_rollback() {
  local expected="${1:-}"
  if [[ ! -f "$KEEL_STATE/pending" ]]; then
    [[ ! -f "$KEEL_STATE/pending-rollback" ]] || {
      keel_warn 'Legacy recovery requires the original installed runtime; see docs/recovery.md.'
      return 1
    }
    return 0
  fi
  keel_transaction_load || return 1
  [[ -z "$expected" || "$expected" == "$KEEL_TX_ID" ]] || return 0
  case "$KEEL_TX_PHASE" in
    committed|rolled_back|aborted) rm -f "$KEEL_STATE/pending"; return 0 ;;
    backed_up|armed) keel_abort_unarmed; return ;;
    applying|awaiting_confirmation|rolling_back|recovery_failed) ;;
    *) keel_warn 'Unknown recovery phase; retaining state.'; return 1 ;;
  esac
  keel_transaction_phase rolling_back || return 1
  if ! keel_restore_security; then
    keel_transaction_phase recovery_failed
    keel_warn 'Recovery failed. Pending state and backups retained; use rescue console and retry sudo keel rollback.'
    return 1
  fi
  keel_transaction_phase rolled_back || return 1
  rm -f "$KEEL_STATE/pending" "$KEEL_STATE/verified" "$KEEL_STATE/secured"
  keel_cancel_timer
  keel_warn 'Previous SSH/UFW configuration restored. Verify access before retrying.'
}
keel_transaction_exit() {
  local rc="$1" phase
  trap - EXIT HUP INT TERM
  if [[ -n "${KEEL_TX:-}" && -f "$KEEL_STATE/pending" ]]; then
    phase="$(cat "$KEEL_TX/phase")"
    if [[ "$phase" == applying ]]; then keel_rollback "" || true; fi
  fi
  exit "$rc"
}
keel_security_digest() {
  # Fingerprints must not depend on the SSH client's forwarded locale or TTY.
  local -x LC_ALL=C COLUMNS=80 TERM=dumb
  local file
  {
    for file in "$KEEL_SSH_DROPIN" /etc/default/ufw /etc/ufw/*; do
      [[ ! -f "$file" ]] || sha256sum "$file" || return 1
    done
    keel_ufw status verbose || return 1
  } | sha256sum | cut -d' ' -f1
}
keel_status() {
  if keel_transaction_load; then
    printf 'Transaction: %s\nPhase: %s\nBackup: %s\n' "$KEEL_TX_ID" "$KEEL_TX_PHASE" "$KEEL_TX"
    keel_systemctl list-timers --no-pager "$(keel_timer_unit).timer"
    echo 'Recovery: sudo keel rollback (keep rescue-console access available).'
  elif [[ -f "$KEEL_STATE/pending-rollback" ]]; then
    echo 'Legacy rollback pending; use the original runtime and docs/recovery.md.'
  elif [[ -f "$KEEL_STATE/secured" ]]; then echo 'Last transaction confirmed; run sudo keel doctor for current checks.'
  else echo 'No pending security transaction.'; fi
}
