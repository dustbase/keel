#!/usr/bin/env bash
# Interactive first-stage configuration. No restrictive network changes.

keel_detect_login() {
  local u="${SUDO_USER:-}"
  if [[ -z "$u" || "$u" == root ]]; then
    read -r -p "Existing SSH login username: " u
  fi
  id "$u" >/dev/null 2>&1 || keel_die "User $u does not exist."
  printf '%s' "$u"
}

keel_init() {
  keel_require_ubuntu
  keel_setup_dirs
  keel_no_pending
  if [[ -f "$KEEL_CONFIG" ]]; then
    keel_load_config
    keel_warn "Existing Keel configuration found for $KEEL_ADMIN on $KEEL_HOST."
    keel_yes "Re-run preparation? No keys will be removed." || exit 0
  fi

  if command -v cloud-init >/dev/null 2>&1; then
    cloud-init status --wait || keel_die 'cloud-init is unfinished or has errors. Resolve it before preparation.'
  fi
  local old_user old_host ts_tag="" chosen name
  old_user="$(keel_detect_login)"
  old_host="$(hostname)"
  echo
  echo "Detected OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "Current account: $old_user"
  echo "Current hostname: $old_host"
  echo "Current authorized keys:"
  keel_key_display "$(getent passwd "$old_user" | cut -d: -f6)/.ssh/authorized_keys"

  read -r -p "New hostname [$old_host]: " name
  KEEL_HOST="${name:-$old_host}"
  keel_valid_hostname "$KEEL_HOST" || keel_die "Invalid hostname."

  local default_admin="$old_user"
  [[ "$default_admin" != root ]] || default_admin="admin"
  read -r -p "Administrator username [$default_admin]: " KEEL_ADMIN
  KEEL_ADMIN="${KEEL_ADMIN:-$default_admin}"
  keel_valid_user "$KEEL_ADMIN" || keel_die "Invalid administrator username."
  keel_existing_admin_safe "$KEEL_ADMIN" || keel_die 'Refusing to promote a system account or account without a usable home/login shell.'

  KEEL_TS=no
  KEEL_TS_MODE=openssh
  if keel_yes "Install/configure Tailscale?"; then
    KEEL_TS=yes
    read -r -p "Tailscale tag (optional; e.g. tag:servers): " ts_tag
    [[ -z "$ts_tag" || "$ts_tag" =~ ^tag:[a-z0-9][a-z0-9-]*$ ]] ||
      keel_die "Invalid tag."
    if keel_yes "Use Tailscale SSH identity authentication? (requires tailnet SSH policy)"; then
      KEEL_TS_MODE=tailscale-ssh
    fi
  fi

  echo
  echo "Firewall profile (applied only after verification):"
  echo "  1) Private: no public application ports [default]"
  echo "  2) Public web: TCP 80 and 443"
  echo "  3) Cloudflare Tunnel: no public inbound application ports"
  echo "  4) Custom: comma-separated TCP or UDP port/protocol pairs"
  read -r -p "Selection [1]: " chosen
  KEEL_CUSTOM=""
  case "${chosen:-1}" in
    1) KEEL_PROFILE=private ;;
    2) KEEL_PROFILE=web ;;
    3) KEEL_PROFILE=tunnel ;;
    4)
      KEEL_PROFILE=custom
      read -r -p "Rules (example: 25565/tcp,51820/udp): " KEEL_CUSTOM
      if ! keel_valid_rules "$KEEL_CUSTOM" || [[ -z "$KEEL_CUSTOM" ]]; then
        keel_die "Invalid custom port rules."
      fi
      ;;
    *) keel_die "Invalid firewall choice." ;;
  esac

  echo
  echo "Plan: hostname=$KEEL_HOST; admin=$KEEL_ADMIN; tailscale=$KEEL_TS"
  echo "Firewall profile=$KEEL_PROFILE; SSH mode=$KEEL_TS_MODE"
  echo "No public application ports by default; current SSH access retained during prepare."
  echo 'Valid keys on the original account will receive access to the destination administrator (sudo).'
  if command -v docker >/dev/null 2>&1; then
    keel_warn 'Docker-published ports can bypass UFW; Keel does not manage Docker networking.'
  fi
  keel_yes "Apply preparation?" || exit 0

  keel_atomic_write "$KEEL_STATE/preparation-status" 'applying (additive steps may have completed; rerun init to resume)'
  keel_log "Installing prerequisites and unattended upgrades"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openssh-server sudo curl ca-certificates ufw unattended-upgrades jq iproute2 util-linux
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'UPDATES'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
UPDATES
  cat > /etc/apt/apt.conf.d/99-keel-no-reboot <<'REBOOT'
Unattended-Upgrade::Automatic-Reboot "false";
REBOOT
  keel_updates_check || keel_die 'Effective APT configuration conflicts with security-update/no-reboot policy.'
  keel_systemctl enable --now apt-daily-upgrade.timer
  keel_install_recovery

  keel_log "Setting hostname and preserving cloud-init hostname"
  hostnamectl set-hostname "$KEEL_HOST"
  install -d /etc/cloud/cloud.cfg.d
  printf '#cloud-config\npreserve_hostname: true\n' \
    > /etc/cloud/cloud.cfg.d/99-keel-hostname.cfg
  if grep -Eq '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^(127\.0\.1\.1[[:space:]]+).*/\1$KEEL_HOST/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$KEEL_HOST" >> /etc/hosts
  fi

  keel_log "Creating or updating administrator"
  if ! id "$KEEL_ADMIN" >/dev/null 2>&1; then
    echo 'Set a local account password for sudo. SSH passwords will be disabled during secure.'
    adduser --gecos "" "$KEEL_ADMIN"
  fi
  usermod -aG sudo "$KEEL_ADMIN"
  keel_keys_setup "$old_user" "$KEEL_ADMIN"

  if [[ "$KEEL_TS" == yes ]]; then
    keel_log "Installing/configuring Tailscale"
    if ! command -v tailscale >/dev/null 2>&1; then
      local installer
      installer="$(mktemp)"
      curl -fsSL https://tailscale.com/install.sh -o "$installer"
      echo "Review the downloaded installer at $installer before execution."
      if keel_yes "Run the official Tailscale installer?"; then
        sh "$installer"
        rm -f "$installer"
      else
        keel_die "Tailscale installation skipped; preparation incomplete."
      fi
    fi
    keel_systemctl enable --now tailscaled
    local args=(--hostname="$KEEL_HOST")
    [[ -z "$ts_tag" ]] || args+=(--advertise-tags="$ts_tag")
    if tailscale ip -4 >/dev/null 2>&1; then
      tailscale set "${args[@]}"
    else
      tailscale up "${args[@]}"
    fi
  fi

  keel_save_config
  keel_atomic_write "$KEEL_STATE/prepared" "$(keel_record_boundary)"
  keel_atomic_write "$KEEL_STATE/preparation-status" complete
  rm -f "$KEEL_STATE/verified" "$KEEL_STATE/secured"
  keel_log "Preparation complete"
  echo "Keep your original SSH session open."
  if [[ "$KEEL_TS_MODE" == tailscale-ssh ]]; then
    echo 'Before verification, configure tailnet SSH policy and run: sudo keel tailscale-ssh'
    echo 'This must happen before verifying the Tailscale SSH authentication mode.'
  fi
  echo "From a NEW terminal, connect as $KEEL_ADMIN using the server IP or MagicDNS."
  echo 'Disable SSH multiplexing for verification: ssh -o ControlMaster=no -o ControlPath=none USER@HOST'
  echo "Then run (without sudo): keel verify"
  echo "Only after verification: keel secure"
}

keel_updates_check() {
  local policy
  policy="$(apt-config dump)" || return 1
  grep -qx 'APT::Periodic::Update-Package-Lists "1";' <<< "$policy" &&
    grep -qx 'APT::Periodic::Unattended-Upgrade "1";' <<< "$policy" &&
    grep -qx 'Unattended-Upgrade::Automatic-Reboot "false";' <<< "$policy"
}
