#!/usr/bin/env bash
# Keel verification and reversible security changes.

keel_current_session() {
  [[ -n "${KEEL_SESSION:-}" ]] ||
    keel_die "A fresh SSH session is required."
  keel_session_dest "$KEEL_SESSION" >/dev/null ||
    keel_die "Malformed SSH session metadata."
  [[ "${SUDO_USER:-}" != root && -n "${SUDO_USER:-}" ]] ||
    keel_die "Run this command as the intended account (without sudo)."
}

keel_verify_identity() {
  keel_load_config
  keel_current_session
  [[ "$SUDO_USER" == "$KEEL_ADMIN" ]] ||
    keel_die "Expected session login as $KEEL_ADMIN, got $SUDO_USER."
  id -nG "$KEEL_ADMIN" | grep -qw sudo ||
    keel_die "$KEEL_ADMIN does not belong to sudo group."
  local dest
  dest="$(keel_session_dest "$KEEL_SESSION")"
  if [[ "$KEEL_TS" == yes ]]; then
    keel_is_tailscale_ip "$dest" ||
      keel_die "SSH destination $dest is not this host's Tailscale IP."
  fi
  # sudo -v in the unprivileged wrapper has already proved sudo.
}

keel_verify() {
  keel_verify_identity
  keel_setup_dirs
  printf '%s\n' "$KEEL_SESSION" > "$KEEL_STATE/verified-session"
  date +%s > "$KEEL_STATE/verified"
  chmod 600 "$KEEL_STATE/verified" "$KEEL_STATE/verified-session"
  keel_log "Verified: new SSH login, administrator account and sudo."
  echo "Next: keel secure (from the new administrator's SSH session)."
}

keel_firewall_preflight() {
  local added
  added="$(ufw show added 2>/dev/null | grep '^ufw ' || true)"
  if [[ -n "$added" ]]; then
    keel_warn "Existing UFW rules require manual review:"
    printf '%s\n' "$added"
    keel_die "Refusing to overwrite or combine unknown firewall rules."
  fi
  grep -qx 'IPV6=yes' /etc/default/ufw ||
    keel_die "Enable IPv6 in /etc/default/ufw before securing."
}

keel_ssh_check() {
  local effective
  /usr/sbin/sshd -t || return 1
  effective="$(/usr/sbin/sshd -T)" || return 1
  local s
  for s in \
    'permitrootlogin no' \
    'passwordauthentication no' \
    'kbdinteractiveauthentication no' \
    'pubkeyauthentication yes'; do
    grep -qx "$s" <<< "$effective" || return 1
  done
}

keel_backup_security() {
  keel_setup_dirs
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  KEEL_ROLLBACK_DIR="$KEEL_BACKUP/$stamp-$$"
  install -d -m 700 "$KEEL_ROLLBACK_DIR"
  if [[ -f "$KEEL_SSH_DROPIN" ]]; then
    cp -p "$KEEL_SSH_DROPIN" "$KEEL_ROLLBACK_DIR/ssh-dropin"
    touch "$KEEL_ROLLBACK_DIR/had-ssh"
  fi
  cp -a /etc/ufw "$KEEL_ROLLBACK_DIR/ufw"
  if ufw status | grep -q '^Status: active'; then
    touch "$KEEL_ROLLBACK_DIR/ufw-was-active"
  fi
  printf '%s\n' "$KEEL_ROLLBACK_DIR" > "$KEEL_STATE/pending-rollback"
  chmod 600 "$KEEL_STATE/pending-rollback"
}

keel_schedule_rollback() {
  command -v systemd-run >/dev/null ||
    keel_die "systemd-run is required for timed rollback."
  # Timer is scheduled BEFORE restrictive changes.
  systemd-run --quiet --unit=keel-security-rollback \
    --on-active=5m /usr/local/bin/keel __rollback ||
    keel_die "Could not schedule automatic rollback."
}

keel_rollback() {
  [[ -f "$KEEL_STATE/pending-rollback" ]] || exit 0
  local backup
  backup="$(cat "$KEEL_STATE/pending-rollback")"
  [[ "$backup" == "$KEEL_BACKUP/"* && -d "$backup/ufw" ]] ||
    keel_die "Invalid rollback path."

  keel_warn "Restoring pre-hardening SSH and UFW configuration."
  if [[ -f "$backup/had-ssh" ]]; then
    cp -p "$backup/ssh-dropin" "$KEEL_SSH_DROPIN"
  else
    rm -f "$KEEL_SSH_DROPIN"
  fi
  /usr/sbin/sshd -t && systemctl reload ssh || \
    keel_warn "SSH configuration validation failed during rollback."

  # Restore original UFW files and status (preflight rejects custom rules).
  ufw --force disable || true
  cp -a "$backup/ufw/." /etc/ufw/
  if [[ -f "$backup/ufw-was-active" ]]; then
    ufw --force enable || keel_warn "UFW enable failed during rollback."
  fi

  rm -f "$KEEL_STATE/pending-rollback" \
    "$KEEL_STATE/secure-session" "$KEEL_STATE/secured"
  keel_warn "Rollback complete. Inspect SSH and UFW before retrying."
}

keel_secure() {
  keel_verify_identity
  [[ -f "$KEEL_STATE/verified" ]] ||
    keel_die "Run 'keel verify' from a new SSH session first."
  local verified_at now
  verified_at="$(cat "$KEEL_STATE/verified")"
  now="$(date +%s)"
  [[ "$verified_at" =~ ^[0-9]+$ ]] ||
    keel_die "Invalid verification state."
  (( now >= verified_at && now - verified_at <= 3600 )) ||
    keel_die "Verification expired; run keel verify again."
  [[ ! -f "$KEEL_STATE/pending-rollback" ]] ||
    keel_die "A rollback is already pending. Use keel confirm or wait."

  if [[ -f "$KEEL_STATE/secured" ]]; then
    keel_log "Already secured. Run keel doctor to audit the configuration."
    return
  fi

  local home
  home="$(getent passwd "$KEEL_ADMIN" | cut -d: -f6)"
  if [[ "$KEEL_TS_MODE" == openssh ]]; then
    [[ -s "$home/.ssh/authorized_keys" ]] ||
      keel_die "No administrator authorized_keys; refusing password lockout."
  fi
  if [[ "$KEEL_TS" == yes ]]; then
    [[ -n "$(tailscale ip -4)" ]] ||
      keel_die "Tailscale is offline."
  fi

  keel_firewall_preflight
  echo
  echo "Security plan:"
  echo "- Disable root/password/keyboard-interactive SSH logins"
  echo "- UFW: deny inbound, allow outbound"
  echo "- SSH: $([[ "$KEEL_TS" == yes ]] && echo 'Tailscale only' || echo 'public TCP 22 (key-only)')"
  echo "- Services: $KEEL_PROFILE (custom: ${KEEL_CUSTOM:-none})"
  echo "- Automatic rollback in FIVE minutes unless confirmed from a new connection"
  echo "- Existing Docker-published ports may bypass UFW!"
  echo
  keel_yes "Apply security changes? Keep the current SSH session open." || return 0

  keel_log "Backing up SSH and firewall and scheduling rollback"
  keel_backup_security
  keel_schedule_rollback
  printf '%s\n' "$KEEL_SESSION" > "$KEEL_STATE/secure-session"

  # Use a drop-in that is loaded early (Ubuntu's default includes drop-ins
  # before main-file settings). Never rewrite the distribution's SSH file.
  cat > "$KEEL_SSH_DROPIN" <<'SSHD'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
SSHD
  if ! keel_ssh_check; then
    keel_rollback
    keel_die "Effective SSH settings failed validation; restored originals."
  fi
  if ! systemctl reload ssh; then
    keel_rollback
    keel_die "Failed to reload SSH; restored originals."
  fi

  ufw default deny incoming
  ufw default allow outgoing
  if [[ "$KEEL_TS" == yes ]]; then
    ufw allow in on tailscale0
  else
    ufw allow 22/tcp
  fi
  case "$KEEL_PROFILE" in
    private|tunnel) ;;
    web)
      ufw allow 80/tcp
      ufw allow 443/tcp
      ;;
    custom)
      local rule
      local -a rules=()
      IFS=, read -ra rules <<< "$KEEL_CUSTOM"
      for rule in "${rules[@]}"; do
        ufw allow "$rule"
      done
      ;;
    *) keel_rollback; keel_die "Unknown firewall profile." ;;
  esac
  if ! ufw --force enable; then
    keel_rollback
    keel_die "Failed to enable UFW; restored originals."
  fi

  keel_log "Hardening applied; rollback is armed for five minutes"
  echo "Open a DIFFERENT, NEW SSH connection and run: keel confirm"
  echo "That new connection MUST succeed before rollback is cancelled."
}

keel_confirm() {
  keel_verify_identity
  [[ -f "$KEEL_STATE/pending-rollback" ]] ||
    keel_die "No pending security change to confirm."
  [[ -f "$KEEL_STATE/secure-session" ]] ||
    keel_die "Missing security session state."
  [[ "$KEEL_SESSION" != "$(cat "$KEEL_STATE/secure-session")" ]] ||
    keel_die "Confirmation must come from a different SSH connection."
  keel_ssh_check || keel_die "SSH settings are not hardened."
  ufw status | grep -q '^Status: active' ||
    keel_die "UFW is not active."
  rm -f "$KEEL_STATE/pending-rollback" "$KEEL_STATE/secure-session"
  touch "$KEEL_STATE/secured"
  chmod 600 "$KEEL_STATE/secured"
  systemctl stop keel-security-rollback.timer 2>/dev/null || true
  keel_log "New SSH connection verified. Rollback cancelled."
  echo "Server is secured. Run: sudo keel doctor"
}

keel_enable_tailscale_ssh() {
  keel_load_config
  [[ "$KEEL_TS" == yes && "$KEEL_TS_MODE" == tailscale-ssh ]] ||
    keel_die "Tailscale SSH was not selected in the configuration."
  echo "Confirm the tailnet SSH ACL allows your login as $KEEL_ADMIN."
  keel_yes "Enable Tailscale SSH? An existing session can be interrupted." || return 0
  tailscale set --ssh
}
