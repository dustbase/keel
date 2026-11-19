#!/usr/bin/env bash
keel_verify() {
  keel_no_pending
  keel_verify_identity
  keel_verify_preparation
  keel_atomic_write "$KEEL_STATE/verified" "$(keel_boot_id) $(keel_ticks) $(keel_config_digest) $KEEL_CONNECTION_ID $KEEL_LOCAL_PORT"
  keel_log 'Verified selected SSH authentication and successful sudo execution.'
  keel_ui_next 'Run keel secure from this verified connection to review the hardening plan.'
}
keel_verify_preparation() {
  local boot ticks digest extra
  [[ -f "$KEEL_STATE/prepared" ]] || keel_die 'No completed preparation is recorded. Run sudo keel init, then open a new SSH connection.'
  # Keep the existing gate authoritative; the branches below only explain refusal.
  if keel_after_boundary "$KEEL_STATE/prepared"; then return 0; fi
  read -r boot ticks digest extra < "$KEEL_STATE/prepared" ||
    keel_die 'Preparation evidence is unreadable or incomplete. Inspect Keel state using recovery access before rerunning preparation.'
  [[ -z "$extra" && "$ticks" =~ ^[0-9]+$ ]] ||
    keel_die 'Preparation evidence is malformed. Inspect Keel state using recovery access before rerunning preparation.'
  [[ "$boot" == "$(keel_boot_id)" ]] ||
    keel_die 'Preparation evidence belongs to a different boot. Run sudo keel init to establish current preparation evidence, then open a new SSH connection.'
  [[ "$digest" == "$(keel_config_digest)" ]] ||
    keel_die 'Prepared settings differ from current intent. Review them and rerun sudo keel init, then open a new SSH connection.'
  if [[ "$KEEL_CONNECTION_START" =~ ^[0-9]+$ ]] && (( KEEL_CONNECTION_START <= ticks )); then
    keel_ui_status WARN 'This SSH connection predates preparation or a Keel runtime update. Do not rerun init solely for this message.' >&2
    keel_reconnect_help verify >&2 || keel_die 'Open a new SSH connection with multiplexing disabled, then run keel verify there.'
    keel_die 'Run verification from that new connection; this session remains available for recovery.'
  fi
  keel_die 'Preparation freshness could not be established. Inspect the recorded boundary using recovery access; verification remains blocked.'
}
keel_reconnect_help() {
  # Presentation only, called after identity verification has established context.
  local action="$1" target="${KEEL_LOCAL_IP:-}" port="${KEEL_LOCAL_PORT:-22}" reconnect
  local ip_target data names short full fallback=''
  local -a args=(ssh -o ControlMaster=no -o ControlPath=none)
  [[ "$action" == verify || "$action" == confirm ]] || return 1
  keel_valid_user "$KEEL_ADMIN" || return 1
  if [[ ! "$target" =~ ^[0-9a-fA-F:.]+$ ]]; then
    keel_valid_hostname "$KEEL_HOST" || return 1
    target="$KEEL_HOST"
  fi
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
  [[ "$port" == 22 ]] || args+=(-p "$port")
  ip_target="$target"
  if [[ "$KEEL_TS" == yes && "${KEEL_LOCAL_IP:-}" =~ ^[0-9a-fA-F:.]+$ ]]; then
    if data="$(keel_tailscale_status_json 2>/dev/null)" && names="$(keel_magicdns_names "$data" "$KEEL_LOCAL_IP")"; then
      read -r short full <<< "$names"
      target="$short"
      printf -v fallback '%q ' "${args[@]}" "$KEEL_ADMIN@$ip_target"
    fi
  fi
  printf -v reconnect '%q ' "${args[@]}" "$KEEL_ADMIN@$target"
  keel_ui_next 'Keep this session open for recovery. Open a NEW terminal on your computer.'
  keel_ui_command 'On your computer' "${reconnect% }"
  keel_ui_command 'In the new login' "keel $action"
  if [[ -n "$fallback" ]]; then
    keel_ui_status INFO "MagicDNS name advertised as $full. Your client must accept tailnet DNS."
    keel_ui_command 'Fallback if the name does not resolve (Tailscale IP)' "${fallback% }"
  elif [[ "$KEEL_TS" == yes ]]; then
    keel_ui_status INFO 'Using the server address because matching MagicDNS metadata could not be confirmed.'
  fi
  if [[ "$KEEL_TS" == no ]]; then
    keel_ui_status INFO 'If you use NAT, a proxy or port forwarding, substitute the original address and port you connected through.'
  fi
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
  keel_ui_section 'Security plan'
  keel_ui_field Server "$KEEL_HOST"
  keel_ui_field Administrator "$KEEL_ADMIN"
  keel_ui_field 'SSH authentication' "$(keel_access_label "$KEEL_TS" "$KEEL_TS_MODE")"
  keel_ui_field 'Public management' "$([[ "$KEEL_TS" == yes ]] && echo closed || echo key-only)"
  keel_ui_field 'Verified SSH port' "$KEEL_LOCAL_PORT"
  keel_ui_field 'Application profile' "$KEEL_PROFILE"
  keel_ui_field 'Custom ports' "${KEEL_CUSTOM:-none}"
  keel_ui_field 'Recovery window' '5 minutes'
  keel_ui_status INFO 'Disable root/password/keyboard-interactive OpenSSH login. UFW will deny inbound and allow outbound.'
  keel_ui_status UNKNOWN 'Tailscale grants and Docker networking are separate controls.'
  keel_ui_status WARN 'Keep this connection and independent rescue-console access available until confirmation.'
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
    keel_rollback "" || keel_die 'Apply and recovery failed; use rescue console.'
    keel_die 'Apply failed; previous SSH/firewall settings restored.'
  fi
  if (( $(keel_ticks) >= $(cat "$KEEL_TX/deadline") )); then
    keel_rollback "" || keel_die 'Apply exceeded the deadline and recovery failed; use rescue console.'
    keel_die 'Apply exceeded the recovery window; previous settings restored.'
  fi
  keel_atomic_write "$KEEL_TX/applied-boundary" "$(keel_record_boundary)"
  keel_atomic_write "$KEEL_TX/applied-digest" "$(keel_security_digest)"
  keel_transaction_phase awaiting_confirmation
  keel_log 'Changes applied; recovery remains armed.'
  keel_reconnect_help confirm || keel_ui_next 'Establish a NEW connection with SSH multiplexing disabled, then run keel confirm. Recovery remains armed.'
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
  keel_ui_next 'Run sudo keel doctor for observed state and remaining limitations.'
}
keel_enable_tailscale_ssh() {
  keel_no_pending
  keel_load_config
  [[ "$KEEL_TS" == yes && "$KEEL_TS_MODE" == tailscale-ssh ]] || keel_die 'Tailscale SSH is not selected.'
  local state
  state="$(keel_tailscale_ssh_state)" || return 1
  case "$state" in
    enabled)
      echo 'Tailscale SSH is already enabled; no server settings changed.'
      echo "Open a fresh interactive Tailscale login as $KEEL_ADMIN@$KEEL_HOST, then run keel verify."
      echo 'A policy denial requires an SSH rule for the destination tag and local user, not another enable attempt.'
      return 0 ;;
    disabled) ;;
    *) keel_die 'Cannot inspect Tailscale SSH state; refusing to switch servers. Check tailscaled and sudo tailscale debug prefs.' ;;
  esac
  if [[ -f "$KEEL_STATE/managed-firewall" ]]; then
    # Reconfiguration must not switch the only known working SSH server out
    # from under an already-hardened host. A verified public key path survives.
    KEEL_TS_MODE=openssh
    if ! keel_session_evidence || keel_is_tailscale_ip "$KEEL_LOCAL_IP"; then
      keel_die 'Before switching a hardened host to Tailscale SSH, establish public key-only recovery access from the console, connect through it, then retry.'
    fi
    KEEL_TS_MODE=tailscale-ssh
  fi
  local -a policy_args=()
  keel_tailscale_policy "${policy_args[@]}" || return 1
  echo "The tailnet must allow BOTH TCP 22 network access and Tailscale SSH as local user $KEEL_ADMIN."
  echo 'A grant for a different server tag, or only autogroup:self, does not cover this tagged server.'
  echo 'Keel cannot prove your external policy permits the future login.'
  keel_yes 'Have you merged and validated the network AND SSH rules for the destination tag and this user?' || return 0
  keel_yes 'Have you tested independent public SSH or provider-console recovery access?' || return 0
  echo 'Enabling Tailscale SSH can interrupt existing tailnet SSH sessions.'
  keel_yes 'Enable Tailscale SSH? Keep public SSH/recovery-console access.' || return 0
  # Persist invalidation before the server switch can disconnect this process.
  rm -f "$KEEL_STATE/verified" "$KEEL_STATE/secured" || return 1
  local boundary
  boundary="$(keel_record_boundary)" || return 1
  keel_atomic_write "$KEEL_STATE/prepared" "$boundary" || return 1
  tailscale set --ssh || {
    keel_warn 'Tailscale SSH enable did not complete normally; its state may have changed. Keep recovery access and inspect the server state before retrying. Verification was invalidated.'
    return 1
  }
  [[ "$(keel_tailscale_ssh_state)" == enabled ]] || {
    keel_warn 'Tailscale SSH enable could not be verified; keep recovery access. No login has been verified.'
    return 1
  }
  echo 'Establish a new Tailscale SSH connection, then run keel verify.'
}
