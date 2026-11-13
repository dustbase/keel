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

keel_key_display() {
  local path="$1"
  if [[ -s "$path" ]]; then
    ssh-keygen -lf "$path" 2>/dev/null || keel_warn "Could not read every key fingerprint in $path"
  else
    printf '(none)\n'
  fi
}

keel_add_key() {
  local dest="$1" entry tmp
  while true; do
    echo "Paste ONE public SSH key on a single line (empty line to finish):"
    IFS= read -r entry || break
    [[ -n "$entry" ]] || break

    tmp="$(mktemp)"
    chmod 600 "$tmp"
    printf '%s\n' "$entry" > "$tmp"
    if ! ssh-keygen -lf "$tmp" >/dev/null 2>&1; then
      keel_warn "Invalid public key. Please try again."
      rm -f "$tmp"
      continue
    fi
    rm -f "$tmp"

    # Exact-line comparison preserves authorized_keys restrictions/options.
    if grep -Fqx -- "$entry" "$dest" 2>/dev/null; then
      echo "This key is already present."
    else
      printf '%s\n' "$entry" >> "$dest"
      echo "Key added."
    fi
  done
}

keel_keys_setup() {
  local original="$1" admin="$2" original_home admin_home admin_group file line
  original_home="$(getent passwd "$original" | cut -d: -f6)"
  admin_home="$(getent passwd "$admin" | cut -d: -f6)"
  admin_group="$(id -gn "$admin")"
  [[ -d "$original_home" && -d "$admin_home" ]] ||
    keel_die "User home directory missing."

  install -d -m 700 -o "$admin" -g "$admin_group" "$admin_home/.ssh"
  file="$admin_home/.ssh/authorized_keys"
  [[ -f "$file" ]] || install -m 600 -o "$admin" -g "$admin_group" /dev/null "$file"

  echo
  echo "Existing SSH keys for $original:"
  keel_key_display "$original_home/.ssh/authorized_keys"
  echo "Existing SSH keys for $admin:"
  keel_key_display "$file"

  if [[ -s "$original_home/.ssh/authorized_keys" &&
        "$original_home/.ssh/authorized_keys" != "$file" ]]; then
    # Keep original authorized_keys entries verbatim, including restrictions.
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      grep -Fqx -- "$line" "$file" || printf '%s\n' "$line" >> "$file"
    done < "$original_home/.ssh/authorized_keys"
  fi

  echo
  if [[ ! -s "$file" ]]; then
    echo "No SSH keys detected. A working key is needed before hardening."
    echo "Generate a key on YOUR computer (not this server):"
    echo '  ssh-keygen -t ed25519 -C "my-computer"'
    echo "Then display and copy its PUBLIC key:"
    echo "  macOS/Linux: cat ~/.ssh/id_ed25519.pub"
    echo '  Windows PowerShell: Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub"'
    echo "Paste the public key below. Never paste your private key."
    keel_add_key "$file"
    [[ -s "$file" ]] || keel_warn "No SSH key configured. Secure phase will not proceed."
  elif keel_yes "Add another SSH public key?"; then
    keel_add_key "$file"
  fi

  chown "$admin:$admin_group" "$file"
  chmod 600 "$file"
  echo
  echo "Authorized keys now configured for $admin:"
  keel_key_display "$file"
}

keel_init() {
  keel_require_ubuntu
  keel_setup_dirs
  if [[ -f "$KEEL_CONFIG" ]]; then
    keel_load_config
    keel_warn "Existing Keel configuration found for $KEEL_ADMIN on $KEEL_HOST."
    keel_yes "Re-run preparation? No keys will be removed." || exit 0
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

  read -r -p "New administrator username: " KEEL_ADMIN
  keel_valid_user "$KEEL_ADMIN" || keel_die "Invalid administrator username."

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
      [[ "$KEEL_CUSTOM" =~ ^[0-9]+/(tcp|udp)(,[0-9]+/(tcp|udp))*$ ]] ||
        keel_die "Invalid rule syntax."
      local rule p
      IFS=, read -ra rules <<< "$KEEL_CUSTOM"
      for rule in "${rules[@]}"; do
        p="${rule%/*}"
        (( 10#$p >= 1 && 10#$p <= 65535 )) ||
          keel_die "Port out of range: $p"
      done
      ;;
    *) keel_die "Invalid firewall choice." ;;
  esac

  echo
  echo "Plan: hostname=$KEEL_HOST; admin=$KEEL_ADMIN; tailscale=$KEEL_TS"
  echo "Firewall profile=$KEEL_PROFILE; SSH mode=$KEEL_TS_MODE"
  echo "Private inbound by default; current SSH access retained during prepare."
  keel_yes "Apply preparation?" || exit 0

  keel_log "Installing prerequisites and unattended upgrades"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openssh-server sudo curl ca-certificates ufw unattended-upgrades
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'UPDATES'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
UPDATES
  systemctl enable --now apt-daily-upgrade.timer

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
    systemctl enable --now tailscaled
    local args=(--hostname="$KEEL_HOST")
    [[ -z "$ts_tag" ]] || args+=(--advertise-tags="$ts_tag")
    if tailscale ip -4 >/dev/null 2>&1; then
      tailscale set "${args[@]}"
    else
      tailscale up "${args[@]}"
    fi
  fi

  keel_save_config
  rm -f "$KEEL_STATE/verified" "$KEEL_STATE/secured"
  keel_log "Preparation complete"
  echo "Keep your original SSH session open."
  echo "From a NEW terminal, connect as $KEEL_ADMIN using the server IP or MagicDNS."
  echo "Then run (without sudo): keel verify"
  echo "Only after verification: keel secure"
}
