#!/usr/bin/env bash
keel_verify() {
  keel_no_pending
  keel_verify_identity
  if [[ ! -f "$KEEL_STATE/prepared" ]] || ! keel_after_boundary "$KEEL_STATE/prepared"; then
    keel_die 'Preparation or intent changed. Re-run init, then establish a new SSH connection.'
  fi
  keel_atomic_write "$KEEL_STATE/verified" "$(keel_boot_id) $(keel_ticks) $(keel_config_digest) $KEEL_CONNECTION_ID $KEEL_LOCAL_PORT"
  keel_log 'Verified selected SSH authentication and successful sudo execution.'
  echo 'Next: keel secure from this connection.'
}
keel_firewall_preflight() {
  local added manager
  for manager in firewalld.service nftables.service; do
    if keel_systemctl is-active --quiet "$manager"; then
      keel_warn "Another firewall manager is active: $manager"
      return 1
    fi
  done
  added="$(keel_ufw show added)" || return 1
  added="$(grep '^ufw ' <<< "$added" || true)"
  if [[ -n "$added" ]]; then
    [[ -f "$KEEL_STATE/managed-rules" && -f "$KEEL_STATE/managed-firewall" && "$(cat "$KEEL_STATE/managed-firewall")" == "$(keel_security_digest)" ]] || {
      keel_warn 'Existing or changed UFW rules require manual review.'
      return 1
    }
  fi
  grep -qx 'IPV6=yes' /etc/default/ufw
}
keel_desired_rules() {
  local scope=public rule
  local -a rules=()
  [[ "$KEEL_TS" != yes ]] || scope=tailscale
  {
    printf '%s %s/tcp\n' "$scope" "$KEEL_LOCAL_PORT"
    case "$KEEL_PROFILE" in
      private|tunnel) ;;
      web) printf 'public 80/tcp\npublic 443/tcp\n' ;;
      custom)
        IFS=, read -ra rules <<< "$KEEL_CUSTOM"
        for rule in "${rules[@]}"; do
          printf 'public %s/%s\n' "$((10#${rule%/*}))" "${rule#*/}"
        done ;;
      *) return 1 ;;
    esac
  } | LC_ALL=C sort -u
}
keel_ufw_rule() {
  local operation="$1" scope="$2" rule="$3"
  local -a args=()
  [[ "$scope" =~ ^(public|tailscale)$ ]] && [[ -n "$rule" && "$rule" != *,* ]] && keel_valid_rules "$rule" || return 1
  case "$operation" in
    add) args=(allow) ;;
    delete) args=(--force delete allow) ;;
    *) return 1 ;;
  esac
  if [[ "$scope" == tailscale ]]; then
    args+=(in on tailscale0 to any port "${rule%/*}" proto "${rule#*/}")
  else args+=("$rule"); fi
  keel_ufw "${args[@]}"
}
keel_apply_security() {
  local desired scope rule extra
  desired="$(keel_desired_rules)" || return 1
  keel_write_ssh || return 1
  keel_ssh_check || return 1
  keel_systemctl reload ssh.service || return 1
  keel_ufw default deny incoming || return 1
  keel_ufw default allow outgoing || return 1
  # Install the replacement management/service access before removing obsolete
  # Keel-owned rules. Never disable/reset an active firewall during a transition.
  while read -r scope rule extra; do
    [[ -z "$extra" ]] && keel_ufw_rule add "$scope" "$rule" || return 1
  done <<< "$desired"
  if [[ -f "$KEEL_STATE/managed-rules" ]]; then
    while read -r scope rule extra; do
      [[ -z "$extra" ]] || return 1
      if ! grep -Fqx -- "$scope $rule" <<< "$desired"; then
        keel_ufw_rule delete "$scope" "$rule" || return 1
      fi
    done < "$KEEL_STATE/managed-rules"
  fi
  keel_ufw --force enable || return 1
  keel_ufw status | grep -q '^Status: active'
}
keel_secure() {
  keel_verify_identity
  keel_no_pending
  local boot ticks digest connection port extra now
  [[ -f "$KEEL_STATE/verified" ]] || keel_die 'Run keel verify first.'
  read -r boot ticks digest connection port extra < "$KEEL_STATE/verified"
  now="$(keel_ticks)"
  [[ -z "$extra" && "$ticks" =~ ^[0-9]+$ && "$boot" == "$(keel_boot_id)" &&
     "$digest" == "$(keel_config_digest)" && "$connection" == "$KEEL_CONNECTION_ID" &&
     "$port" == "$KEEL_LOCAL_PORT" ]] || keel_die 'Verification is stale or belongs to another connection. Run keel verify.'
  (( now >= ticks && now - ticks <= 3600 * $(getconf CLK_TCK) )) || keel_die 'Verification expired.'
  if [[ -f "$KEEL_STATE/secured" && "$(cat "$KEEL_STATE/secured")" == "$digest" ]] &&
     keel_ssh_check && [[ "$(cat "$KEEL_STATE/managed-firewall")" == "$(keel_security_digest)" ]]; then
    keel_log 'Intended SSH/firewall configuration is already applied.'
    return 0
  fi
  keel_ssh_preflight || keel_die 'Unsupported SSH Include/Match/service configuration; see docs/security.md.'
  if [[ "$KEEL_TS_MODE" == openssh ]]; then
    keel_listener_check || keel_die 'Verified port is not an active OpenSSH listener.'
  fi
  keel_firewall_preflight || keel_die 'UFW preflight failed; review existing rules and IPv6 configuration.'
  echo 'Security plan: disable root/password/keyboard-interactive OpenSSH login.'
  printf 'Public management access: %s; verified SSH port: %s\n' "$([[ "$KEEL_TS" == yes ]] && echo closed || echo key-only)" "$KEEL_LOCAL_PORT"
  printf 'Public application profile: %s (%s)\n' "$KEEL_PROFILE" "${KEEL_CUSTOM:-no custom ports}"
  echo 'UFW will deny inbound and allow outbound. Tailscale grants and Docker networking are separate controls.'
  echo 'Recovery deadline: five minutes. Keep this connection and rescue-console access available.'
  keel_yes 'Apply these changes?' || return 0
  keel_backup_security || keel_die 'Backup failed; restrictive changes were not applied.'
  if ! keel_schedule_rollback; then
    keel_abort_unarmed || keel_die 'Scheduling failed; run sudo keel rollback to clear recovery state.'
    keel_die 'Recovery could not be armed; no restrictive changes applied. Retry secure.'
  fi
  trap 'keel_transaction_exit $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  keel_transaction_phase applying
  if ! keel_apply_security; then
    keel_rollback || keel_die 'Apply and recovery failed; use rescue console.'
    keel_die 'Apply failed; previous SSH/firewall settings restored.'
  fi
  if (( $(keel_ticks) >= $(cat "$KEEL_TX/deadline") )); then
    keel_rollback || keel_die 'Apply exceeded the deadline and recovery failed; use rescue console.'
    keel_die 'Apply exceeded the recovery window; previous settings restored.'
  fi
  keel_atomic_write "$KEEL_TX/applied-boundary" "$(keel_record_boundary)"
  keel_atomic_write "$KEEL_TX/applied-digest" "$(keel_security_digest)"
  keel_transaction_phase awaiting_confirmation
  keel_log 'Changes applied; recovery remains armed.'
  echo 'Establish a NEW connection (disable SSH multiplexing), then run: keel confirm'
}
keel_confirm() {
  keel_verify_identity
  keel_transaction_load || keel_die 'No pending transaction.'
  [[ "$KEEL_TX_PHASE" == awaiting_confirmation ]] || keel_die "Cannot confirm phase $KEEL_TX_PHASE; run sudo keel status."
  local deadline
  deadline="$(cat "$KEEL_TX/deadline")"
  [[ "$deadline" =~ ^[0-9]+$ && "$(cat "$KEEL_TX/boot")" == "$(keel_boot_id)" ]] || keel_die 'Invalid or prior-boot transaction; recover it.'
  (( $(keel_ticks) < deadline )) || keel_die 'Recovery deadline expired; run sudo keel rollback.'
  [[ "$(cat "$KEEL_TX/management-port")" == "$KEEL_LOCAL_PORT" ]] || keel_die 'Confirm using the management port verified before hardening.'
  keel_after_boundary "$KEEL_TX/applied-boundary" || keel_die 'Confirmation requires a connection authenticated after hardening completed, with unchanged intent.'
  keel_ssh_check || keel_die 'SSH policy validation failed; recovery remains armed.'
  [[ "$(cat "$KEEL_TX/applied-digest")" == "$(keel_security_digest)" ]] || keel_die 'Applied firewall/SSH configuration changed; recover and retry.'
  # The terminal decision is durable before timer/pending cleanup. A service
  # already waiting for the lock sees committed and must not restore the backup.
  (( $(keel_ticks) < deadline )) || keel_die 'Recovery deadline expired during validation; recovery remains armed.'
  keel_transaction_phase committed
  keel_atomic_write "$KEEL_STATE/secured" "$(keel_config_digest)"
  keel_atomic_write "$KEEL_STATE/managed-rules" "$(keel_desired_rules)"
  keel_atomic_write "$KEEL_STATE/managed-firewall" "$(keel_security_digest)"
  rm -f "$KEEL_STATE/pending"
  keel_cancel_timer
  keel_log 'Post-change SSH access confirmed. Recovery cancelled.'
  echo 'Run sudo keel doctor for observed state and remaining limitations.'
}
keel_enable_tailscale_ssh() {
  keel_no_pending
  keel_load_config
  [[ "$KEEL_TS" == yes && "$KEEL_TS_MODE" == tailscale-ssh ]] || keel_die 'Tailscale SSH is not selected.'
  if [[ -f "$KEEL_STATE/managed-firewall" ]] && ! tailscale debug prefs | jq -e '.RunSSH == true' >/dev/null; then
    # Reconfiguration must not switch the only known working SSH server out
    # from under an already-hardened host. A verified public key path survives.
    KEEL_TS_MODE=openssh
    if ! keel_session_evidence || keel_is_tailscale_ip "$KEEL_LOCAL_IP"; then
      keel_die 'Before switching a hardened host to Tailscale SSH, establish public key-only recovery access from the console, connect through it, then retry.'
    fi
    KEEL_TS_MODE=tailscale-ssh
  fi
  echo 'Configure the tailnet network and SSH policies for this administrator first.'
  echo 'Enabling Tailscale SSH can interrupt existing tailnet SSH sessions.'
  keel_yes 'Enable Tailscale SSH? Keep public SSH/recovery-console access.' || return 0
  tailscale set --ssh
  rm -f "$KEEL_STATE/verified" "$KEEL_STATE/secured"
  keel_atomic_write "$KEEL_STATE/prepared" "$(keel_record_boundary)"
  echo 'Establish a new Tailscale SSH connection, then run keel verify.'
}
